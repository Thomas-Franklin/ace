# frozen_string_literal: true

require 'hocon'
require 'bolt_server/base_config'

module ACE
  class Config < BoltServer::BaseConfig
    attr_reader :data
    def config_keys
      super + %w[concurrency cache-dir file-server-conn-timeout file-server-uri ssl-ca-crls]
    end

    def env_keys
      super + %w[concurrency file-server-conn-timeout file-server-uri ssl-ca-crls]
    end

    def ssl_keys
      super + %w[ssl-ca-crls]
    end

    def int_keys
      %w[concurrency file-server-conn-timeout]
    end

    def defaults
      super.merge(
        'port' => 44633,
        'concurrency' => 10,
        'cache-dir' => "/opt/puppetlabs/server/data/ace-server/cache",
        'file-server-conn-timeout' => 120
      )
    end

    def required_keys
      super + %w[file-server-uri cache-dir]
    end

    def service_name
      'ace-server'
    end

    def load_env_config
      env_keys.each do |key|
        transformed_key = "ACE_#{key.tr('-', '_').upcase}"
        next unless ENV.key?(transformed_key)
        @data[key] = if int_keys.include?(key)
                       ENV[transformed_key].to_i
                     else
                       ENV[transformed_key]
                     end
      end
    end

    def validate
      super

      unless natural?(@data['concurrency'])
        raise Bolt::ValidationError, "Configured 'concurrency' must be a positive integer"
      end

      unless natural?(@data['file-server-conn-timeout'])
        raise Bolt::ValidationError, "Configured 'file-server-conn-timeout' must be a positive integer"
      end
    end
  end
end
