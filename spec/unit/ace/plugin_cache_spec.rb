# frozen_string_literal: true

require 'ace/plugin_cache'
require 'webmock/rspec'
require 'hocon'

RSpec.describe ACE::PluginCache do
  let(:puppetserver_files) { "#{RSPEC_ROOT}/spec/fixtures/puppet_server_files" }
  let(:base_config) { 
   {"ssl-cert" => "spec/fixtures/ssl/cert.pem",
    "ssl-key" => "spec/fixtures/ssl/key.pem",
    "ssl-ca-cert" => "spec/fixtures/ssl/ca.pem",
    "ssl-ca-crls" => "spec/fixtures/ssl/crl.pem",
    "file-server-uri" => "https://localhost:8140",
    "cache-dir" => "/tmp"}
 }

  describe '#setup_ssl' do
    it {
      expect(described_class.new(base_config).setup_ssl).to be_a(Puppet::SSL::SSLContext)
    }
  end

  before(:each) do
    Puppet::Util::Log.destinations.clear
  end

  describe '#sync' do
    it {
      stub_request(:get, "https://0.0.0.0:8140/puppet/v3/file_metadatas/pluginfacts?checksum_type=md5&environment=production&ignore=.hg&links=follow&recurse=true&source_permissions=use").
      with(
        headers: {
          'Accept'=>'application/json, text/pson',
          'Accept-Encoding'=>'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
          'User-Agent'=>'Puppet/6.4.0 Ruby/2.5.1-p57 (x86_64-darwin17)',
          'X-Puppet-Version'=>'6.4.0'
          }).
          to_return(status: 200, body: '[{"path":"/etc/puppetlabs/code/environments/production/modules","relative_path":".","links":"follow","owner":0,"group":0,"mode":493,"checksum":{"type":"ctime","value":"{ctime}2019-03-28 10:53:51 +0000"},"type":"directory","destination":null}]', headers: {content_type: 'application/json'})
      stub_request(:get, "https://0.0.0.0:8140/puppet/v3/file_metadata/pluginfacts?checksum_type=md5&environment=production&links=follow&source_permissions=use").
         with(
           headers: {
           'Accept'=>'application/json, text/pson',
           'Accept-Encoding'=>'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
           'User-Agent'=>'Puppet/6.4.0 Ruby/2.5.1-p57 (x86_64-darwin17)',
           'X-Puppet-Version'=>'6.4.0'
           }).
         to_return(status: 200, body: '{"message":"Not Found: Could not find file_metadata pluginfacts","issue_kind":"RESOURCE_NOT_FOUND"}', headers: {content_type: 'application/json'})
       stub_request(:get, "https://0.0.0.0:8140/puppet/v3/file_metadatas/plugins?checksum_type=md5&environment=production&ignore=.hg&links=follow&recurse=true&source_permissions=ignore").
         with(
           headers: {
       	  'Accept'=>'application/json, text/pson',
       	  'Accept-Encoding'=>'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
       	  'User-Agent'=>'Puppet/6.4.0 Ruby/2.5.1-p57 (x86_64-darwin17)',
       	  'X-Puppet-Version'=>'6.4.0'
           }).
         to_return(status: 200, body: "[
          {\"path\":\"#{puppetserver_files}\",\"relative_path\":\".\",\"links\":\"follow\",\"owner\":999,\"group\":999,\"mode\":420,\"checksum\":{\"type\":\"ctime\",\"value\":\"{ctime}2019-03-28 10:53:51 +0000\"},\"type\":\"directory\",\"destination\":null},
          {\"path\":\"#{puppetserver_files}\",\"relative_path\":\"fake_file.rb\",\"links\":\"follow\",\"owner\":999,\"group\":999,\"mode\":420,\"checksum\":{\"type\":\"md5\",\"value\":\"{md5}acbd18db4cc2f85cedef654fccc4a4d8\"},\"type\":\"file\",\"destination\":null}
          ]", headers: {content_type: 'application/json'})
       stub_request(:get, "https://0.0.0.0:8140/puppet/v3/file_metadata/plugins?checksum_type=md5&environment=production&links=follow&source_permissions=ignore").
         with(
           headers: {
       	  'Accept'=>'application/json, text/pson',
       	  'Accept-Encoding'=>'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
       	  'User-Agent'=>'Puppet/6.4.0 Ruby/2.5.1-p57 (x86_64-darwin17)',
       	  'X-Puppet-Version'=>'6.4.0'
           }).
         to_return(status: 200, body: '{"path":"spec/fixtures/puppet_server_files/fake_file.rb","relative_path":null,"links":"follow","owner":999,"group":999,"mode":420,"checksum":{"type":"md5","value":"{md5}acbd18db4cc2f85cedef654fccc4a4d8"},"type":"file","destination":null}', headers: {content_type: 'application/json'})
       stub_request(:get, "https://0.0.0.0:8140/puppet/v3/file_content/plugins/fake_file.rb?environment=production").
         with(
           headers: {
           'Accept'=>'application/octet-stream',
           'Accept-Encoding'=>'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
           'User-Agent'=>'Ruby'
           }).
         to_return(status: 200, body: "foo", headers: {})
       expect(described_class.new(base_config).sync('production')).to be_a(String)
    }
  end
end
