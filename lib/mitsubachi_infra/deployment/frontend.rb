# frozen_string_literal: true

require 'fileutils'
require_relative 'release_manager'

module MitsubachiInfra
  module Deployment
    class Frontend
      def initialize(config:, runner:, health:)
        @config = config
        @runner = runner
        @health = health
      end

      def deploy(ref: nil)
        app = @config.fetch('frontend')
        deploy_user = @config.fetch('deploy').fetch('user')
        manager = ReleaseManager.new(root: @config.frontend_root, runner: @runner, keep: app.fetch('keep_releases'))
        manager.ensure_dirs(owner: deploy_user)
        repo = @config.frontend_repository_cache
        fetch_repository(app.fetch('repository'), repo, ref || app.fetch('ref'))
        sha = @runner.deploy('git', "--git-dir=#{repo}", 'rev-parse', '--verify',
                             "#{ref || app.fetch('ref')}^{commit}", config: @config).stdout.strip
        release = File.join(manager.releases_dir, manager.release_id(sha))
        begin
          @runner.deploy('mkdir', '-p', release, config: @config)
          @runner.deploy('git', "--git-dir=#{repo}", "--work-tree=#{release}", 'checkout', '-f', sha, '--', '.',
                         config: @config)
          @runner.deploy('npm', 'ci', config: @config, chdir: release, timeout: 1800)
          @runner.deploy(*app.fetch('build_command'), config: @config, chdir: release, timeout: 1800)
          index = File.join(release, app.fetch('output_directory'), 'index.html')
          raise Error, "frontend build output missing index.html: #{index}" unless @runner.dry_run || File.exist?(index)

          manager.activate(release) unless @runner.dry_run
          @health.check!(frontend_health_url, dry_run: @runner.dry_run)
          manager.cleanup
        rescue StandardError
          FileUtils.rm_rf(release) unless @runner.dry_run || manager.current_release == release
          raise
        end
      end

      private

      def fetch_repository(url, repo, ref)
        if File.directory?(File.join(repo, 'objects'))
          @runner.deploy('git', "--git-dir=#{repo}", 'remote', 'set-url', 'origin', url, config: @config)
          @runner.deploy('git', "--git-dir=#{repo}", 'fetch', '--prune', 'origin', ref, config: @config, timeout: 1800)
        else
          @runner.deploy('git', 'clone', '--mirror', url, repo, config: @config, timeout: 1800)
        end
      end

      def frontend_health_url
        @config.public? ? "https://#{@config.frontend_host}/" : "http://#{@config.fetch('server_ip')}/"
      end
    end
  end
end
