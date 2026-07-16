# frozen_string_literal: true

require_relative 'errors'

module MitsubachiInfra
  class RailsCommand
    BASE_ENV = {
      'RAILS_ENV' => 'production',
      'RACK_ENV' => 'production',
      'BUNDLE_WITHOUT' => 'development:test'
    }.freeze

    def initialize(config:, runner:)
      @config = config
      @runner = runner
    end

    def rails(*args, release:, timeout: 600)
      @runner.deploy('bundle', 'exec', 'rails', *args, config: @config, chdir: release, timeout: timeout,
                                                    env: rails_env)
    end

    def runner(script, release:, timeout: 600)
      rails('runner', script, release: release, timeout: timeout)
    end

    def env_file_values
      path = @config.fetch('paths').fetch('rails_env')
      return {} if @runner.dry_run && !File.exist?(path)
      raise Error, "Rails env file is missing: #{path}" unless File.exist?(path)

      File.readlines(path, chomp: true).each_with_object({}) do |line, env|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?('#')
        raise Error, "invalid Rails env line in #{path}" unless stripped.include?('=')

        key, value = stripped.split('=', 2)
        raise Error, "invalid Rails env key in #{path}: #{key}" unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        env[key] = unquote(value)
      end
    end

    private

    def rails_env
      env_file_values.merge(BASE_ENV)
    end

    def unquote(value)
      return value[1...-1] if value.start_with?('"') && value.end_with?('"')

      value
    end
  end
end
