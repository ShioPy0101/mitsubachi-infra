# frozen_string_literal: true

require 'fileutils'
require 'time'

module MitsubachiInfra
  module Deployment
    class Maintenance
      def initialize(path:, runner:, logger: $stderr)
        @path = path
        @runner = runner
        @logger = logger
      end

      def enable
        return log('already enabled') if enabled?
        return log("[DRY-RUN] enable #{@path}") if @runner.dry_run

        FileUtils.mkdir_p(File.dirname(@path))
        temp = "#{@path}.tmp.#{$PROCESS_ID}"
        File.write(temp, "enabled_at=#{Time.now.iso8601}\n", mode: 'w', perm: 0o644)
        File.rename(temp, @path)
        log("enabled #{@path}")
      ensure
        FileUtils.rm_f(temp) if defined?(temp) && temp
      end

      def disable
        return log('already disabled') unless enabled?
        return log("[DRY-RUN] disable #{@path}") if @runner.dry_run

        FileUtils.rm_f(@path)
        log("disabled #{@path}")
      end

      def enabled?
        File.file?(@path)
      end

      private

      def log(message)
        @logger.puts("[MAINTENANCE] #{message}")
        true
      end
    end
  end
end
