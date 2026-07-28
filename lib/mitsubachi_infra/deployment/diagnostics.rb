# frozen_string_literal: true

require 'fileutils'

module MitsubachiInfra
  module Deployment
    class Diagnostics
      def initialize(config:, runner:, logger: $stderr)
        @config = config
        @runner = runner
        @logger = logger
      end

      def capture(directory)
        return [] if @runner.dry_run

        FileUtils.mkdir_p(directory)
        commands.each_with_index.map do |(name, argv), index|
          result = @runner.run(*argv, allow_failure: true, timeout: 60)
          path = File.join(directory, format('%02d-%s.txt', index + 1, name))
          File.write(path, "exit_code=#{result.status}\nstdout:\n#{result.stdout}\nstderr:\n#{result.stderr}", mode: 'w', perm: 0o640)
          path
        rescue StandardError => e
          @logger.puts("[DIAGNOSTICS] #{name} failed without replacing deployment error: #{e.message}")
          nil
        end.compact
      end

      private

      def commands
        api = @config.fetch('release').fetch('api_service')
        worker = @config.fetch('release').fetch('worker_service')
        url = "http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/ready"
        [
          ['api-status', ['systemctl', 'status', api, '--no-pager']],
          ['worker-status', ['systemctl', 'status', worker, '--no-pager']],
          ['api-journal', ['journalctl', '-u', api, '-n', '200', '--no-pager']],
          ['worker-journal', ['journalctl', '-u', worker, '-n', '200', '--no-pager']],
          ['listening-sockets', %w[ss -lntp]],
          ['health-curl', ['curl', '-v', '-H', "Host: #{@config.health_host}", url]]
        ]
      end
    end
  end
end
