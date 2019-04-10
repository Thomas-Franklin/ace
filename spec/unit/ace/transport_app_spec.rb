# frozen_string_literal: true

require 'spec_helper'
require 'ace/error'
require 'ace/transport_app'
require 'rack/test'
require 'ace/config'

RSpec.describe ACE::TransportApp do
  include Rack::Test::Methods

  def app
    ACE::TransportApp.new(ACE::Config.new(cache_dir))
  end

  let(:cache_dir) { { "cache-dir" => "/foo" } }
  let(:executor) { instance_double(Bolt::Executor, 'executor') }
  let(:file_cache) { instance_double(BoltServer::FileCache, 'file_cache') }
  let(:task_response) { instance_double(Bolt::ResultSet, 'task_response') }
  let(:plugins) { instance_double(ACE::PluginCache, 'plugin_cache') }
  let(:response) { instance_double(Bolt::Result, 'response') }

  let(:status) do
    {
      node: "fw.example.net",
      status: "success",
      result: {
        "output" => "Hello!"
      }
    }
  end
  let(:body) do
    {
      'task': echo_task,
      'target': connection_info,
      'parameters': { "message": "Hello!" }
    }
  end
  let(:execute_catalog_body) do
    {
      "target": {
        "remote-transport": "panos",
        "host": "fw.example.net",
        "user": "foo",
        "password": "wibble"
      },
      "compiler": {
        "certname": certname,
        "environment": "development",
        "transaction_uuid": "<uuid string>",
        "job_id": "<id string>"
      }
    }
  end
  let(:echo_task) do
    {
      'name': 'sample::echo',
      'metadata': {
        'description': 'Echo a message',
        'parameters': { 'message': 'Default message' }
      },
      files: [{
        filename: "echo.sh",
        sha256: "foo",
        uri: {}
      }]
    }
  end
  let(:connection_info) do
    {
      'remote-transport': 'panos',
      'address': 'hostname',
      'username': 'user',
      'password': 'password'
    }
  end

  before do
    allow(Bolt::Executor).to receive(:new).and_return(executor)
    allow(BoltServer::FileCache).to receive(:new).and_return(file_cache)
    allow(ACE::PluginCache).to receive(:new).and_return(plugins)
    allow(file_cache).to receive(:setup)
    allow(plugins).to receive(:setup).and_return(plugins)
  end

  describe '/' do
    it 'responds ok' do
      get '/'
      expect(last_response).to be_ok
      expect(last_response.status).to eq(200)
    end
  end

  ################
  # Tasks Endpoint
  ################
  describe '/run_task' do
    before do
      allow(ACE::ForkUtil).to receive(:isolate).and_yield

      allow(executor).to receive(:run_task).with(
        match_array(instance_of(Bolt::Target)),
        kind_of(Bolt::Task),
        "message" => "Hello!"
      ).and_return(task_response)

      allow(task_response).to receive(:first).and_return(response)
      allow(response).to receive(:status_hash).and_return(status)
    end

    it 'throws an ace/schema_error if the request is invalid' do
      post '/run_task', JSON.generate({}), 'CONTENT_TYPE' => 'text/json'

      expect(last_response.body).to match(%r{puppetlabs\/ace\/schema-error})
      expect(last_response.status).to eq(400)
    end

    it 'throws an ace/request_exception if the request is invalid JSON' do
      post '/run_task', '{ foo }', 'CONTENT_TYPE' => 'text/json'

      expect(last_response.body).to match(%r{puppetlabs\/ace\/request_exception})
      expect(last_response.status).to eq(400)
    end

    context 'when the task executes cleanly' do
      it 'runs returns the output' do
        post '/run_task', JSON.generate(body), 'CONTENT_TYPE' => 'text/json'

        expect(last_response.errors).to match(/\A\Z/)
        expect(last_response).to be_ok
        expect(last_response.status).to eq(200)
        result = JSON.parse(last_response.body)
        expect(result).to include('status' => 'success')
        expect(result['result']['output']).to eq('Hello!')
      end
    end

    context 'when the task executed returns a `backtrace`' do
      let(:status) do
        {
          node: "fw.example.net",
          status: "failure",
          result: {
            '_error' => {
              'msg' => 'Failed to open TCP connection to fw.example.net',
              'kind' => 'module/unknown',
              'details' => {
                'class' => 'SocketError',
                'backtrace' => [
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:906:in `rescue in block in connect'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:903:in `block in connect'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/timeout.rb:93:in `block in timeout'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/timeout.rb:103:in `timeout'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:902:in `connect'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:887:in `do_start'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:882:in `start'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:608:in `start'"
                ]
              }
            }
          }
        }
      end

      it 'runs returns the output and removes the error' do
        post '/run_task', JSON.generate(body), 'CONTENT_TYPE' => 'text/json'

        expect(last_response.errors).to match(/\A\Z/)
        expect(last_response).to be_ok
        expect(last_response.status).to eq(200)
        result = JSON.parse(last_response.body)
        expect(result).to include('status' => 'failure')
        expect(result['result']['_error']).not_to have_key('backtrace')
      end
    end

    context 'when the task executed returns a `stack_trace`' do
      let(:status) do
        {
          node: "fw.example.net",
          status: "failure",
          result: {
            '_error' => {
              'msg' => 'Failed to open TCP connection to fw.example.net',
              'kind' => 'module/unknown',
              'details' => {
                'class' => 'SocketError',
                'stack_trace' => [
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:906:in `rescue in block in connect'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:903:in `block in connect'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/timeout.rb:93:in `block in timeout'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/timeout.rb:103:in `timeout'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:902:in `connect'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:887:in `do_start'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:882:in `start'",
                  "/Users/foo/.rbenv/versions/2.4.1/lib/ruby/2.4.0/net/http.rb:608:in `start'"
                ]
              }
            }
          }
        }
      end

      it 'runs returns the output and removes the error' do
        post '/run_task', JSON.generate(body), 'CONTENT_TYPE' => 'text/json'

        expect(last_response.errors).to match(/\A\Z/)
        expect(last_response).to be_ok
        expect(last_response.status).to eq(200)
        result = JSON.parse(last_response.body)
        expect(result).to include('status' => 'failure')
        expect(result['result']['_error']).not_to have_key('stack_trace')
      end
    end
  end

  describe '/check' do
    it 'calls the correct method' do
      post '/check', {}, 'CONTENT_TYPE' => 'text/json'

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq('OK')
    end
  end

  ##################
  # Catalog Endpoint
  ##################
  describe '/execute_catalog' do
    before {
      allow(plugins).to receive(:with_synced_libdir)
    }

    describe 'success' do
      let(:certname) { 'fw.example.net' }

      it 'returns 200 with empty body when success' do
        post '/execute_catalog', JSON.generate(execute_catalog_body), 'CONTENT_TYPE' => 'text/json'
        expect(last_response.errors).to match(/\A\Z/)
        expect(last_response).to be_ok
        expect(last_response.status).to eq(200)
        result = JSON.parse(last_response.body)
        expect(result).to eq({})
      end
    end

    describe 'catalog compile failed' do
      let(:certname) { 'fail.example.net' }

      it 'returns 200 with error in body' do
        post '/execute_catalog', JSON.generate(execute_catalog_body), 'CONTENT_TYPE' => 'text/json'
        expect(last_response.errors).to match(/\A\Z/)
        expect(last_response).to be_ok
        expect(last_response.status).to eq(200)
        result = JSON.parse(last_response.body)
        expect(result).to include('_error')
        expect(result['_error']['msg']).to eq('catalog compile failed')
      end
    end

    describe 'bad request' do
      it 'throws an ace/request_exception if the request is invalid JSON' do
        post '/execute_catalog', '{ foo }', 'CONTENT_TYPE' => 'text/json'

        expect(last_response.body).to match(%r{puppetlabs\/ace\/request_exception})
        expect(last_response.status).to eq(400)
      end
    end

    describe 'target specification invalid' do
      let(:certname) { 'credentials.example.net' }

      it 'returns 200 with error in body' do
        post '/execute_catalog', JSON.generate(execute_catalog_body), 'CONTENT_TYPE' => 'text/json'
        expect(last_response.errors).to match(/\A\Z/)
        expect(last_response).to be_ok
        expect(last_response.status).to eq(200)
        result = JSON.parse(last_response.body)
        expect(result).to include('_error')
        expect(result['_error']['msg']).to eq('target specification invalid')
      end
    end

    describe 'report submission failed' do
      let(:certname) { 'reports.example.net' }

      it 'returns 200 with error in body' do
        post '/execute_catalog', JSON.generate(execute_catalog_body), 'CONTENT_TYPE' => 'text/json'
        expect(last_response.errors).to match(/\A\Z/)
        expect(last_response).to be_ok
        expect(last_response.status).to eq(200)
        result = JSON.parse(last_response.body)
        expect(result).to include('_error')
        expect(result['_error']['msg']).to eq('report submission failed')
      end
    end
  end

  ##################
  # init_puppet_target function
  ##################
  describe 'init_puppet_target' do
    describe 'success with transport style connection info' do
      device_raw = '{
            "target": {
                "remote-transport":"panos",
                "host":"fw.example.net",
                "user":"foo",
                "password":"wibble"
            },
            "compiler": {
                "certname":"fw.example.net",
                "environment":"development",
                "transaction_uuid":"<uuid string>",
                "job_id":"<id string>"
            }
        }'
      device_json = JSON.parse(device_raw)
      test_hash = Hash[device_json['target'].map { |(k, v)| [k.to_sym, v] }]
      test_hash.delete(:"remote-transport")
      # Our actual function inits a device, mocking this out with a simple return string for the purposes of test
      it 'returns correct device' do
        allow(Puppet::Util::NetworkDevice).to receive(:init) do |params|
          expect(params[:provider]).to eq(device_json['target']['remote-transport'])
          expect(params[:url]).to eq(test_hash)
          expect(params[:name]).to eq(device_json['compiler']['certname'])
          expect(params[:options]).to eql({})
          'panos_device'
        end

        expect(described_class.init_puppet_target(device_json['compiler']['certname'],
                                                  device_json['target']['remote-transport'],
                                                  device_json['target'])).to match(/(panos_device)/)
      end
    end

    describe 'success with legacy style uri' do
      device_raw = '{
          "target":{
            "remote-transport":"f5",
            "uri":"https://foo:wibble@f5.example.net/"
          },
          "compiler":{
            "certname":"f5.example.net",
            "environment":"development",
            "transaction_uuid":"<uuid string>",
            "job_id":"<id string>"
          }
        }'
      device_json = JSON.parse(device_raw)
      # Our actual function inits a device, mocking this out with a simple return string for the purposes of test
      it 'returns correct device' do
        allow(Puppet::Util::NetworkDevice).to receive(:init) do |params|
          expect(params[:provider]).to eq(device_json['target']['remote-transport'])
          expect(params[:url]).to eq(device_json['target']['uri'])
          expect(params[:name]).to eq(device_json['compiler']['certname'])
          expect(params[:options]).to eql({})
          'f5_device'
        end

        expect(described_class.init_puppet_target(device_json['compiler']['certname'],
                                                  device_json['target']['remote-transport'],
                                                  device_json['target'])).to match(/(f5_device)/)
      end
    end
    # rubocop:disable RSpec/MessageSpies

    describe 'raise error when invalid uri supplied' do
      device_raw = '{
          "target":{
            "remote-transport":"f5",
            "uri":"£$ %^%£$@ ^£@£"
          },
          "compiler":{
            "certname":"f5.example.net",
            "environment":"development",
            "transaction_uuid":"<uuid string>",
            "job_id":"<id string>"
          }
        }'
      device_json = JSON.parse(device_raw)
      it 'throws error and returns nil device' do
        allow(ACE::Error).to receive(:new).with('There was an error parsing the URI of the Puppet target',
                                                'puppetlabs/ace/invalid_param')
        expect(Puppet::Util::NetworkDevice).not_to receive(:init)

        expect(described_class.init_puppet_target(device_json['compiler']['certname'],
                                                  device_json['target']['remote-transport'],
                                                  device_json['target'])).to be_nil
      end
    end

    describe 'raise error when json supplied does not contain target' do
      device_raw = '{
          "compiler":{
            "certname":"f5.example.net",
            "environment":"development",
            "transaction_uuid":"<uuid string>",
            "job_id":"<id string>"
          }
        }'
      device_json = JSON.parse(device_raw)
      it 'throws error and returns nil device' do
        allow(ACE::Error).to receive(:new).with("There was an error parsing the Puppet target. 'target' not found",
                                                'puppetlabs/ace/invalid_param')
        expect(Puppet::Util::NetworkDevice).not_to receive(:init)

        expect(described_class.init_puppet_target(device_json['compiler']['certname'],
                                                  'cisco_ios',
                                                  nil)).to be_nil
      end
    end

    describe 'raise error when json supplied does not contain compiler certname' do
      device_raw = '{
          "target": {
                "remote-transport":"panos",
                "host":"fw.example.net",
                "user":"foo",
                "password":"wibble"
          },
          "compiler": {
            "environment":"development",
            "transaction_uuid":"<uuid string>",
            "job_id":"<id string>"
          }
        }'
      device_json = JSON.parse(device_raw)
      it 'throws error and returns nil device' do
        allow(ACE::Error).to receive(:new).with("There was an error parsing the Puppet compiler details. "\
                                                "'certname' not found",
                                                'puppetlabs/ace/invalid_param')
        expect(Puppet::Util::NetworkDevice).not_to receive(:init)

        expect(described_class.init_puppet_target(nil,
                                                  device_json['target']['remote-transport'],
                                                  device_json['target'])).to be_nil
      end
    end

    describe 'raise error when json supplied does not contain remote-transport' do
      device_raw = '{
          "target":{
            "uri":"https://foo:wibble@f5.example.com"
          },
          "compiler": {
            "certname":"f5.example.net",
            "environment":"development",
            "transaction_uuid":"<uuid string>",
            "job_id":"<id string>"
          }
        }'
      device_json = JSON.parse(device_raw)
      it 'throws error and returns nil device' do
        allow(ACE::Error).to receive(:new).with(
          "There was an error parsing the Puppet target. 'transport' not found",
          'puppetlabs/ace/invalid_param'
        )
        expect(Puppet::Util::NetworkDevice).not_to receive(:init)

        expect(described_class.init_puppet_target(device_json['compiler']['certname'],
                                                  nil,
                                                  device_json['target'])).to be_nil
      end
    end
    # rubocop:enable RSpec/MessageSpies
  end
end
