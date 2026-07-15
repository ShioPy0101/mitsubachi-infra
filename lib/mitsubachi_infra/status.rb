# frozen_string_literal: true

require "json"
require_relative "deployment/release_manager"

module MitsubachiInfra
  class Status
    def initialize(config:, runner:, systemd:, health:)
      @config = config
      @runner = runner
      @systemd = systemd
      @health = health
    end

    def data
      {
        deployment_mode: @config.fetch("deployment_mode"),
        deploy_user: @config.fetch("deploy").fetch("user"),
        backend_current: manager(@config.backend_root, "backend").current_release,
        frontend_current: manager(@config.frontend_root, "frontend").current_release,
        backend_releases: manager(@config.backend_root, "backend").release_paths.length,
        frontend_releases: manager(@config.frontend_root, "frontend").release_paths.length,
        backend_systemd_active: @systemd.active?("mitsubachi-api.service"),
        config_path: Configuration::CONFIG_PATH,
        nginx_syntax: @runner.run("nginx", "-t", allow_failure: true).success?,
        ufw_status: @runner.run("ufw", "status", allow_failure: true).stdout.lines.first.to_s.strip
      }
    end

    def print(json: false)
      snapshot = data
      if json
        puts JSON.pretty_generate(snapshot)
      else
        snapshot.each { |key, value| puts "#{key}: #{value}" }
      end
    end

    private

    def manager(root, key)
      Deployment::ReleaseManager.new(root: root, runner: @runner, keep: @config.fetch(key).fetch("keep_releases"))
    end
  end
end
