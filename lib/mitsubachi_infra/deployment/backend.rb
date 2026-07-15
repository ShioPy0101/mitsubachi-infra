# frozen_string_literal: true

require "fileutils"
require_relative "release_manager"

module MitsubachiInfra
  module Deployment
    class Backend
      SERVICE = "mitsubachi-api.service"

      def initialize(config:, runner:, systemd:, health:)
        @config = config
        @runner = runner
        @systemd = systemd
        @health = health
      end

      def deploy(ref: nil)
        app = @config.fetch("backend")
        deploy_user = @config.fetch("deploy").fetch("user")
        manager = ReleaseManager.new(root: @config.backend_root, runner: @runner, keep: app.fetch("keep_releases"))
        manager.ensure_dirs(owner: deploy_user)
        repo = File.join(@config.repositories_root, "backend.git")
        fetch_repository(app.fetch("repository"), repo, ref || app.fetch("ref"))
        sha = @runner.deploy("git", "--git-dir=#{repo}", "rev-parse", "--verify", "#{ref || app.fetch("ref")}^{commit}", config: @config).stdout.strip
        release = File.join(manager.releases_dir, manager.release_id(sha))
        previous = manager.current_release
        begin
          @runner.deploy("mkdir", "-p", release, config: @config)
          @runner.deploy("git", "--git-dir=#{repo}", "--work-tree=#{release}", "checkout", "-f", sha, "--", ".", config: @config)
          install_bundle(release)
          link_shared(release, manager.shared_dir)
          rails_check(release)
          @runner.deploy("bundle", "exec", "rails", "db:migrate", config: @config, chdir: release, timeout: 1800)
          manager.activate(release) unless @runner.dry_run
          @systemd.restart(SERVICE)
          @health.check!(backend_health_url, dry_run: @runner.dry_run)
          manager.cleanup(protected_paths: [previous].compact)
        rescue StandardError
          FileUtils.rm_rf(release) unless @runner.dry_run || manager.current_release == release
          if previous && manager.current_release == release
            manager.activate(previous)
            @systemd.restart(SERVICE)
          end
          raise
        end
      end

      private

      def fetch_repository(url, repo, ref)
        if File.directory?(File.join(repo, "objects"))
          @runner.deploy("git", "--git-dir=#{repo}", "remote", "set-url", "origin", url, config: @config)
          @runner.deploy("git", "--git-dir=#{repo}", "fetch", "--prune", "origin", ref, config: @config, timeout: 1800)
        else
          @runner.deploy("git", "clone", "--mirror", url, repo, config: @config, timeout: 1800)
        end
      end

      def install_bundle(release)
        lock = File.join(release, "Gemfile.lock")
        if File.exist?(lock)
          version = File.readlines(lock).each_cons(2).find { |a, _b| a.strip == "BUNDLED WITH" }&.last&.strip
          @runner.deploy("gem", "list", "--installed", "--exact", "bundler", "--version", version, config: @config, allow_failure: true) if version
          @runner.deploy("gem", "install", "bundler", "--version", version, "--no-document", config: @config) if version
        end
        @runner.deploy("bundle", "config", "set", "--local", "deployment", "true", config: @config, chdir: release)
        @runner.deploy("bundle", "config", "set", "--local", "without", "development test", config: @config, chdir: release)
        @runner.deploy("bundle", "install", config: @config, chdir: release, timeout: 1800)
      end

      def link_shared(release, shared)
        %w[log tmp].each { |dir| FileUtils.mkdir_p(File.join(shared, dir)) unless @runner.dry_run }
        %w[log tmp].each do |dir|
          target = File.join(release, dir)
          FileUtils.rm_rf(target) unless @runner.dry_run
          FileUtils.ln_s(File.join(shared, dir), target) unless @runner.dry_run
        end
      end

      def rails_check(release)
        required = %w[DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL]
        env = "/etc/mitsubachi/rails.env"
        text = File.exist?(env) ? File.read(env) : ""
        missing = required.reject { |key| text.match?(/^#{Regexp.escape(key)}=.+/) }
        raise Error, "missing Rails database env keys: #{missing.join(", ")}" unless missing.empty? || @runner.dry_run

        @runner.deploy("bundle", "exec", "rails", "runner", "ActiveRecord::Base.connection.execute('SELECT 1')", config: @config, chdir: release, timeout: 300)
        @runner.deploy("bundle", "exec", "rails", "runner", "Rails.application.eager_load!", config: @config, chdir: release, timeout: 300)
      end

      def backend_health_url
        if @config.public?
          "https://#{@config.fetch("https").fetch("host")}#{@config.fetch("backend").fetch("health_path")}"
        else
          "http://#{@config.fetch("server_ip")}#{@config.fetch("backend").fetch("health_path")}"
        end
      end
    end
  end
end
