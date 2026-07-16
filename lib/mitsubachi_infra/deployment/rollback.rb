# frozen_string_literal: true

require_relative 'release_manager'

module MitsubachiInfra
  module Deployment
    class Rollback
      def initialize(config:, runner:, systemd:, health:)
        @config = config
        @runner = runner
        @systemd = systemd
        @health = health
      end

      def rollback(target)
        case target
        when 'backend' then rollback_backend
        when 'frontend' then rollback_frontend
        when 'all'
          rollback_backend
          rollback_frontend
        else
          raise ValidationError, 'rollback target must be backend, frontend, or all'
        end
      end

      private

      def rollback_backend
        manager = ReleaseManager.new(root: @config.backend_root, runner: @runner,
                                     keep: @config.fetch('backend').fetch('keep_releases'))
        target = manager.previous_release
        if target.nil? && @runner.dry_run
          warn "[DRY-RUN] backend rollback candidate would be selected from #{manager.releases_dir}"
          return
        end
        raise Error, 'backend rollback candidate not found' if target.nil?

        warn 'backend rollback does not roll back DB migrations'
        manager.activate(target) unless @runner.dry_run
        @systemd.restart('mitsubachi-api.service')
        @health.check!(backend_health_url, dry_run: @runner.dry_run, host: @config.health_host)
      end

      def rollback_frontend
        manager = ReleaseManager.new(root: @config.frontend_root, runner: @runner,
                                     keep: @config.fetch('frontend').fetch('keep_releases'))
        target = manager.previous_release
        if target.nil? && @runner.dry_run
          warn "[DRY-RUN] frontend rollback candidate would be selected from #{manager.releases_dir}"
          return
        end
        raise Error, 'frontend rollback candidate not found' if target.nil?

        manager.activate(target) unless @runner.dry_run
        @health.check!(frontend_health_url, dry_run: @runner.dry_run)
      end

      def backend_health_url
        @config.public? ? "https://#{@config.api_host}/api/health/ready" : "http://#{@config.fetch('server_ip')}/api/health/ready"
      end

      def frontend_health_url
        @config.public? ? "https://#{@config.frontend_host}/" : "http://#{@config.fetch('server_ip')}/"
      end
    end
  end
end
