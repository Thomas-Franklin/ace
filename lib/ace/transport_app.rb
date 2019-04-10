# frozen_string_literal: true

require 'ace/error'
require 'ace/fork_util'
require 'ace/plugin_cache'
require 'bolt_server/file_cache'
require 'bolt/executor'
require 'bolt/inventory'
require 'bolt/target'
require 'bolt/task/puppet_server'
require 'json-schema'
require 'json'
require 'sinatra'
require 'puppet/util/network_device/base'

module ACE
  class TransportApp < Sinatra::Base
    def initialize(config = nil)
      @config = config
      @executor = Bolt::Executor.new(0, load_config: false)
      tasks_cache_dir = File.join(@config['cache-dir'], 'tasks')
      @file_cache = BoltServer::FileCache.new(@config.data.merge('cache-dir' => tasks_cache_dir)).setup
      environments_cache_dir = File.join(@config['cache-dir'], 'environments')
      @plugins = ACE::PluginCache.new(@config.data.merge('cache-dir' => environments_cache_dir)).setup

      @schemas = {
        "run_task" => JSON.parse(File.read(File.join(__dir__, 'schemas', 'ace-run_task.json'))),
        "execute_catalog" => JSON.parse(File.read(File.join(__dir__, 'schemas', 'ace-execute_catalog.json')))
      }
      shared_schema = JSON::Schema.new(JSON.parse(File.read(File.join(__dir__, 'schemas', 'task.json'))),
                                       Addressable::URI.parse("file:task"))
      JSON::Validator.add_schema(shared_schema)

      super(nil)
    end

    # Initialises the puppet target.
    # @param certname   The certificate name of the target.
    # @param transport  The transport provider of the target.
    # @param target     Target connection hash or legacy connection URI
    # @return [Puppet device instance] Returns Puppet device instance, or nil if exception thrown
    # @raise  [puppetlabs/ace/invalid_param] If nil parameter or no connection detail found
    # @example Connect to device.
    #   init_puppet_target('test_device.domain.com', 'panos',  JSON.parse("target":{
    #                                                                       "remote-transport":"panos",
    #                                                                       "host":"fw.example.net",
    #                                                                       "user":"foo",
    #                                                                       "password":"wibble"
    #                                                                     }) ) => panos.device
    def self.init_puppet_target(certname, transport, target)
      unless target
        ACE::Error.new("There was an error parsing the Puppet target. 'target' not found",
                       'puppetlabs/ace/invalid_param')
        return nil
      end
      unless certname
        ACE::Error.new("There was an error parsing the Puppet compiler details. 'certname' not found",
                       'puppetlabs/ace/invalid_param')
        return nil
      end
      unless transport
        ACE::Error.new("There was an error parsing the Puppet target. 'transport' not found",
                       'puppetlabs/ace/invalid_param')
        return nil
      end

      if target['uri']
        if target['uri'] =~ URI::DEFAULT_PARSER.make_regexp
          # Correct URL
          url = target['uri']
        else
          ACE::Error.new("There was an error parsing the URI of the Puppet target",
                         'puppetlabs/ace/invalid_param')
          return nil
        end
      else
        url = Hash[target.map { |(k, v)| [k.to_sym, v] }]
        url.delete(:"remote-transport")
      end

      device_struct = Struct.new(:provider, :url, :name, :options)
      # Return device
      Puppet::Util::NetworkDevice.init(device_struct.new(transport,
                                                         url,
                                                         certname,
                                                         {}))
    end

    def scrub_stack_trace(result)
      if result.dig(:result, '_error', 'details', 'stack_trace')
        result[:result]['_error']['details'].reject! { |k| k == 'stack_trace' }
      end
      if result.dig(:result, '_error', 'details', 'backtrace')
        result[:result]['_error']['details'].reject! { |k| k == 'backtrace' }
      end
      result
    end

    def ssl_context
      @ssl_context ||= Puppet::SSL::SSLProvider.new.create_context(
        cacerts: [OpenSSL::X509::Certificate.new(File.read(@config['ssl-ca-cert']))],
        crls: [OpenSSL::X509::CRL.new(File.read(@config['ssl-ca-crls']))],
        private_key: OpenSSL::PKey::RSA.new(File.read(@config['ssl-key'])),
        client_cert: OpenSSL::X509::Certificate.new(File.read(@config['ssl-cert']))
      )
    end

    def validate_schema(schema, body)
      schema_error = JSON::Validator.fully_validate(schema, body)
      if schema_error.any?
        ACE::Error.new("There was an error validating the request body.",
                       'puppetlabs/ace/schema-error',
                       schema_error)
      end
    end

    # returns a hash of trusted facts that will be used
    # to request a catalog for the target
    def self.trusted_facts(certname)
      # assumes that the certname will be a valid FQDN
      hostname, domain = certname.split('.', 2)
      trusted_facts = {
        "authenticated": "remote",
        "extensions": {},
        "certname": certname,
        "hostname": hostname
      }
      trusted_facts[:domain] = domain if domain
      trusted_facts
    end

    get "/" do
      200
    end

    post "/check" do
      [200, 'OK']
    end

    # :nocov:
    if ENV['RACK_ENV'] == 'dev'
      get '/admin/gc' do
        GC.start
        200
      end
    end

    get '/admin/gc_stat' do
      [200, GC.stat.to_json]
    end
    # :nocov:

    # run this with "curl -X POST http://0.0.0.0:44633/run_task -d '{}'"
    post '/run_task' do
      content_type :json

      begin
        body = JSON.parse(request.body.read)
      rescue StandardError => e
        request_error = {
          _error: ACE::Error.new(e.message,
                                 'puppetlabs/ace/request_exception',
                                 class: e.class, backtrace: e.backtrace)
        }
        return [400, request_error.to_json]
      end

      error = validate_schema(@schemas["run_task"], body)
      return [400, error.to_json] unless error.nil?

      opts = body['target'].merge('protocol' => 'remote')

      # This is a workaround for Bolt due to the way it expects to receive the target info
      # see: https://github.com/puppetlabs/bolt/pull/915#discussion_r268280535
      # Systems calling into ACE will need to determine the nodename/certname and pass this as `name`
      target = [Bolt::Target.new(body['target']['host'] || body['target']['name'], opts)]

      inventory = Bolt::Inventory.new(nil)

      target.first.inventory = inventory

      task = Bolt::Task::PuppetServer.new(body['task'], @file_cache)

      parameters = body['parameters'] || {}

      result = ForkUtil.isolate do
        # Since this will only be on one node we can just return the first result
        results = @executor.run_task(target, task, parameters)
        scrub_stack_trace(results.first.status_hash)
      end
      [200, result.to_json]
    end

    post '/execute_catalog' do
      content_type :json

      begin
        body = JSON.parse(request.body.read)
      rescue StandardError => e
        request_error = {
          _error: ACE::Error.new(e.message,
                                 'puppetlabs/ace/request_exception',
                                 class: e.class, backtrace: e.backtrace)
        }
        return [400, request_error.to_json]
      end

      error = validate_schema(@schemas["execute_catalog"], body)
      return [400, error.to_json] unless error.nil?

      environment = body['compiler']['environment']
      certname = body['compiler']['certname']

      @plugins.with_synced_libdir(environment, certname) do
        Puppet.push_context(Puppet.base_context(Puppet.settings), "Initial context after settings initialization")
        pool = Puppet::Network::HTTP::NoCachePool.new
        env = Puppet::Node::Environment.remote(environment)
        Puppet.override(ssl_context: ssl_context, http_pool: pool, loaders: Puppet::Pops::Loaders.new(env), configured_environment: environment) do
          Puppet::Transaction::Report.indirection.terminus_class = :rest
          ACE::TransportApp.init_puppet_target(certname, body['target']['remote-transport'], body['target'])
          configurer = Puppet::Configurer.new(body['compiler']['transaction_uuid'], body['compiler']['job_id'])
          configurer.run(:network_device => true, :pluginsync => false, :trusted_facts => ACE::TransportApp.trusted_facts(certname))
        end
      end

      # simulate expected error cases
      if body['compiler']['certname'] == 'fail.example.net'
        [200, { _error: {
          msg: 'catalog compile failed',
          kind: 'puppetlabs/ace/compile_failed',
          details: 'upstream api errors go here'
        } }.to_json]
      elsif body['compiler']['certname'] == 'credentials.example.net'
        [200, { _error: {
          msg: 'target specification invalid',
          kind: 'puppetlabs/ace/target_spec',
          details: 'upstream api errors go here'
        } }.to_json]
      elsif body['compiler']['certname'] == 'reports.example.net'
        [200, { _error: {
          msg: 'report submission failed',
          kind: 'puppetlabs/ace/reporting_failed',
          details: 'upstream api errors go here'
        } }.to_json]
      else
        [200, '{}']
      end
    end
  end
end
