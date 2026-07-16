# frozen_string_literal: true

require 'fileutils'
require_relative '../frontend_env'
require_relative 'release_manager'

module MitsubachiInfra
  module Deployment
    class Frontend
      def initialize(config:, runner:, health:, logger: $stderr)
        @config = config
        @runner = runner
        @health = health
        @logger = logger
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
          env = FrontendEnv.new(config: @config, logger: @logger)
          env.log_summary(build_dir: release)
          @runner.deploy(*app.fetch('build_command'), config: @config, chdir: release, timeout: 1800,
                                                    env: env.build_env)
          env.verify_build_output!(release: release, output_directory: app.fetch('output_directory'),
                                   dry_run: @runner.dry_run)

          @logger.puts("[SWITCH] frontend current -> #{release}")
          manager.activate(release) unless @runner.dry_run
          @runner.run('nginx', '-t')
          @runner.run('systemctl', 'reload', 'nginx')
          @health.check!(frontend_health_url, dry_run: @runner.dry_run, host: frontend_health_host,
                                               allow_redirect: @config.public?)
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
        @config.public? ? 'http://127.0.0.1/' : "http://#{@config.fetch('server_ip')}/"
      end

      def frontend_health_host
        @config.public? ? @config.frontend_host : nil
      end

    end
  end
end
