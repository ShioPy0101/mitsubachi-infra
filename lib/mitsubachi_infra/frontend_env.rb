# frozen_string_literal: true

require 'uri'
require_relative 'errors'

module MitsubachiInfra
  class FrontendEnv
    VITE_API_BASE_URL = 'VITE_API_BASE_URL'
    SECRET_KEY_PATTERN = /(SECRET|TOKEN|PASSWORD|KEY)/i

    attr_reader :path, :env

    def initialize(config:, path: config.fetch('paths').fetch('frontend_env'), logger: $stderr)
      @config = config
      @path = path
      @logger = logger
      @env = File.exist?(path) ? self.class.parse_file(path) : {}
    end

    def self.parse_file(path)
      File.readlines(path, chomp: true).each_with_object({}) do |line, env|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?('#')

        key, value = stripped.split('=', 2)
        next unless key&.match?(/\A[A-Z0-9_]+\z/)

        env[key] = value.to_s.strip
      end
    end

    def build_env
      validate!
      { VITE_API_BASE_URL => vite_api_base_url }
    end

    def vite_api_base_url
      env.fetch(VITE_API_BASE_URL, '').to_s.strip
    end

    def validate!
      value = vite_api_base_url
      if value.empty?
        raise Error, "#{VITE_API_BASE_URL} is not configured.\nSet it in #{path} before deploying the frontend."
      end
      raise Error, "#{VITE_API_BASE_URL} must not contain newline or NUL" if value.match?(/[\n\r\0]/)

      uri = URI.parse(value)
      raise Error, "#{VITE_API_BASE_URL} must start with http:// or https://" unless %w[http https].include?(uri.scheme)
      raise Error, "#{VITE_API_BASE_URL} must include a host" if uri.host.to_s.empty?

      if @config.public? && %w[localhost 127.0.0.1].include?(uri.host)
        raise Error, "#{VITE_API_BASE_URL} must not point to #{uri.host} in public mode"
      end

      true
    rescue URI::InvalidURIError
      raise Error, "#{VITE_API_BASE_URL} is invalid"
    end

    def log_summary(build_dir:)
      @logger.puts("[INFO] Frontend build directory: #{build_dir}")
      @logger.puts("[INFO] Frontend env file: #{path}")
      @logger.puts("[INFO] #{VITE_API_BASE_URL}: #{vite_api_base_url}")
    end

    def masked_entries
      env.to_h do |key, value|
        [key, key.match?(SECRET_KEY_PATTERN) ? '<redacted>' : value]
      end
    end
  end
end
