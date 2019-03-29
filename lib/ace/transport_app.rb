# frozen_string_literal: true

require 'ace/fork_util'
require 'bolt/executor'
require 'bolt/inventory'
require 'ace/plugin_cache'
require 'bolt/target'
require 'bolt_server/file_cache'
require 'bolt/task'
require 'bolt_server/file_cache'
require 'json'
require 'json-schema'
require 'sinatra'

module ACE
  class TransportApp < Sinatra::Base
    def initialize(config = nil)
      @config = config
      @executor = Bolt::Executor.new(0, load_config: false)
      cache_dir = config['cache-dir'].dup
      @tasks_dir = File.join(cache_dir, 'tasks')
      @file_cache = BoltServer::FileCache.new(@config).setup
      @environments_dir = File.join(cache_dir, 'environments')
      config['cache-dir'].sub!(cache_dir, @environments_dir)
      @plugins = ACE::PluginCache.new(@config).setup

      @schemas = {
        "run_task" => JSON.parse(File.read(File.join(__dir__, 'schemas', 'ace-run_task.json'))),
        "execute_catalog" => JSON.parse(File.read(File.join(__dir__, 'schemas', 'ace-execute_catalog.json')))
      }
      shared_schema = JSON::Schema.new(JSON.parse(File.read(File.join(__dir__, 'schemas', 'task.json'))),
                                       Addressable::URI.parse("file:task"))
      JSON::Validator.add_schema(shared_schema)

      super(nil)
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

    def validate_schema(schema, body)
      schema_error = JSON::Validator.fully_validate(schema, body)
      if schema_error.any?
        ACE::Error.new("There was an error validating the request body.",
                       'ace/schema-error',
                       schema_error)
      end
    end

    get "/" do
      200
    end

    post "/check" do
      [200, 'OK']
    end

    # run this with "curl -X POST http://0.0.0.0:44633/run_task -d '{}'"
    post '/run_task' do
      content_type :json

      body = JSON.parse(request.body.read)
      error = validate_schema(@schemas["run_task"], body)
      return [400, error.to_json] unless error.nil?

      opts = body['target'].merge('protocol' => 'remote')

      # This is a workaround for Bolt due to the way it expects to receive the target info
      # see: https://github.com/puppetlabs/bolt/pull/915#discussion_r268280535
      # Systems calling into ACE will need to determine the nodename/certname and pass this as `name`
      target = [Bolt::Target.new(body['target']['host'] || body['target']['name'], opts)]

      inventory = Bolt::Inventory.new(nil)

      target.first.inventory = inventory

      task = Bolt::Task.new(body['task'], @file_cache)

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

      body = JSON.parse(request.body.read)
      error = validate_schema(@schemas["execute_catalog"], body)
      return [400, error.to_json] unless error.nil?

      result = ForkUtil.isolate do
        @plugins.sync(body['compiler']['environment'])
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
        [200, { _success: {
          msg: result
        } }.to_json]
      end
    end
  end
end
