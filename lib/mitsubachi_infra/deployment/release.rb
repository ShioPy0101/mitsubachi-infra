# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require_relative '../errors'
require_relative '../frontend_env'
require_relative '../health_check'
require_relative '../lock'
require_relative '../rails_command'
require_relative 'database_backup'
require_relative 'diagnostics'
require_relative 'maintenance'
require_relative 'migration'
require_relative 'preflight'
require_relative 'release_manager'
require_relative 'release_report'
require_relative 'smoke_tester'
require_relative 'step_result'

module MitsubachiInfra
  module Deployment
    class Release
      def initialize(config:, runner:, logger: $stderr, health: nil, preflight: nil, smoke_tester: nil,
                     maintenance: nil, database_backup: nil, migration: nil, diagnostics: nil, lock: nil)
        @config = config
        @runner = runner
        @logger = logger
        @health = health || HealthCheck.new(logger: logger)
        @preflight = preflight || Preflight.new(config: config, runner: runner, logger: logger)
        @smoke_tester = smoke_tester || SmokeTester.new(config: config, runner: runner, logger: logger)
        @rails = RailsCommand.new(config: config, runner: runner)
        @maintenance = maintenance || Maintenance.new(path: release_config.fetch('maintenance_flag'), runner: runner,
                                                                                                      logger: logger)
        @database_backup = database_backup || DatabaseBackup.new(config: config, runner: runner,
                                                                 rails_command: @rails, logger: logger)
        @migration = migration || Migration.new(rails_command: @rails, runner: runner)
        @diagnostics = diagnostics || Diagnostics.new(config: config, runner: runner, logger: logger)
        @lock = lock || proc { |&block| Lock.with(&block) }
      end

      def deploy(backend_ref:, frontend_ref:)
        preflight_started = Time.now
        begin
          @preflight.check!(backend_ref: backend_ref, frontend_ref: frontend_ref, dry_run: @runner.dry_run)
        rescue StandardError => error
          save_preflight_failure(backend_ref, frontend_ref, preflight_started, error) unless @runner.dry_run
          raise
        end
        release_id = generate_release_id
        @logger.puts("[RELEASE] candidate release_id=#{release_id}")
        return dry_run(release_id, backend_ref, frontend_ref) if @runner.dry_run

        report = ReleaseReport.new(release_id: release_id, root: release_config.fetch('backup_root'),
                                   backend_ref: backend_ref, frontend_ref: frontend_ref)
        report.record(StepResult.new(name: 'preflight', succeeded: true, started_at: preflight_started,
                                     completed_at: Time.now))
        @runner.run('install', '-d', '-o', 'root', '-g', @config.fetch('deploy').fetch('user'), '-m', '0770',
                    report.directory)
        begin
          @lock.call { execute_locked(report, backend_ref: backend_ref, frontend_ref: frontend_ref) }
        rescue StandardError => error
          if report.data[:status] == 'running'
            report.finish(status: 'failed', failed_step: 'deployment_lock', error: error.message,
                          exit_code: error.respond_to?(:status) ? error.status : 1)
          end
          raise
        end
        report.data
      end

      def dry_run(release_id, backend_ref, frontend_ref)
        report = ReleaseReport.new(release_id: release_id, root: release_config.fetch('backup_root'),
                                   backend_ref: backend_ref, frontend_ref: frontend_ref, dry_run: true)
        planned_steps.each { |step| @logger.puts("[DRY-RUN] release step: #{step}") }
        report.finish(status: 'dry_run')
        report.data
      end

      private

      def execute_locked(report, backend_ref:, frontend_ref:)
        state = { migration_started: false, switched: false, previous_backend: nil, previous_frontend: nil }
        begin
          run_step(report, 'maintenance_enable') do
            @maintenance.enable
            report.merge(:maintenance, enabled_at: Time.now.iso8601)
          end
          run_step(report, 'database_backup') do
            backup = @database_backup.create!(report.directory)
            report.merge(:database_backup, backup)
          end
          backend_release = nil
          frontend_release = nil
          run_step(report, 'pre_migration_snapshot') do
            snapshot_release = current_release(backend_root)
            raise Error, 'current backend release is required for pre-migration snapshot task' unless snapshot_release

            output = report.path('pre_migration_counts.json')
            @migration.snapshot!(release: snapshot_release, output: output)
          end
          run_step(report, 'backend_prepare') do
            backend_release, revision = prepare_backend(report.data.fetch(:release_id), backend_ref)
            report.assign(backend_revision: revision)
          end
          run_step(report, 'frontend_prepare') do
            frontend_release, revision = prepare_frontend(report.data.fetch(:release_id), frontend_ref)
            report.assign(frontend_revision: revision)
          end
          state[:migration_started] = true
          run_step(report, 'database_migration') do
            @migration.migrate!(release: backend_release)
            report.merge(:migration, command_succeeded: true)
          end
          run_step(report, 'migration_verification') do
            path = report.path('migration_report.json')
            @migration.verify!(release: backend_release, output: path)
            report.merge(:migration, verification_succeeded: true, report_path: path)
          end
          run_step(report, 'release_switch') do
            state[:previous_backend] = current_release(backend_root)
            state[:previous_frontend] = current_release(frontend_root)
            report.assign(previous_backend_release_id: release_basename(state[:previous_backend]),
                          previous_frontend_release_id: release_basename(state[:previous_frontend]))
            switch_pair!(backend_release, frontend_release, state)
          end
          run_step(report, 'service_restart') { restart_services }
          run_step(report, 'nginx_reload') { reload_nginx }
          run_step(report, 'readiness_health_check') do
            result = health_check(report.path('health_check_report.json'))
            report.merge(:health_check, result.to_h)
          rescue StandardError
            @diagnostics.capture(report.path('diagnostics'))
            raise
          end
          run_step(report, 'smoke_test') do
            path = report.path('smoke_test_report.json')
            @smoke_tester.run!(release_id: report.data.fetch(:release_id), output: path)
            report.merge(:smoke_test, succeeded: true, report_path: path)
          end
          run_step(report, 'maintenance_disable') do
            @maintenance.disable
            report.merge(:maintenance, disabled_at: Time.now.iso8601)
          end
          cleanup_releases(state)
          report.finish(status: 'succeeded', exit_code: 0)
        rescue StandardError => error
          failed_step = @current_step
          rollback_after_failure(state, report)
          safe_disable_before_migration(state, report)
          record_migration_failure(report, failed_step, error)
          record_component_failure(report, failed_step, error)
          report.finish(status: 'failed', failed_step: failed_step, error: error.message,
                        exit_code: error.respond_to?(:status) ? error.status : 1)
          raise
        end
      end

      def save_preflight_failure(backend_ref, frontend_ref, started, error)
        release_id = generate_release_id
        report = ReleaseReport.new(release_id: release_id, root: release_config.fetch('backup_root'),
                                   backend_ref: backend_ref, frontend_ref: frontend_ref)
        report.record(StepResult.new(name: 'preflight', succeeded: false, started_at: started,
                                     completed_at: Time.now, details: { error: error.message }))
        report.finish(status: 'failed', failed_step: 'preflight', error: error.message,
                      exit_code: error.respond_to?(:status) ? error.status : 1)
      rescue StandardError => report_error
        @logger.puts("[REPORT] could not save preflight failure report: #{report_error.message}")
      end

      def record_migration_failure(report, failed_step, error)
        return unless %w[database_migration migration_verification].include?(failed_step)

        values = failed_step == 'database_migration' ? { command_succeeded: false } : { verification_succeeded: false }
        report.merge(:migration, values.merge(error: error.message, report_path: report.path('migration_report.json')))
        return if File.file?(report.path('migration_report.json'))

        File.write(report.path('migration_report.json'),
                   JSON.pretty_generate(values.merge(error: error.message)) + "\n", mode: 'w', perm: 0o640)
      rescue StandardError => report_error
        @logger.puts("[REPORT] could not save migration failure detail: #{report_error.message}")
      end

      def record_component_failure(report, failed_step, error)
        case failed_step
        when 'readiness_health_check'
          path = report.path('health_check_report.json')
          values = File.file?(path) ? JSON.parse(File.read(path), symbolize_names: true) : {}
          report.merge(:health_check, values.merge(succeeded: false, error: error.message, report_path: path))
        when 'smoke_test'
          report.merge(:smoke_test, succeeded: false, error: error.message,
                                    report_path: report.path('smoke_test_report.json'))
        end
      rescue StandardError => report_error
        @logger.puts("[REPORT] could not save component failure detail: #{report_error.message}")
      end

      def run_step(report, name)
        @current_step = name
        started = Time.now
        @logger.puts("[STEP] #{name}")
        value = yield
        report.record(StepResult.new(name: name, succeeded: true, started_at: started,
                                     completed_at: Time.now, output_files: step_outputs(name)))
        value
      rescue StandardError => e
        report.record(StepResult.new(name: name, succeeded: false, started_at: started,
                                     completed_at: Time.now, details: { error: e.message }))
        raise
      end

      def prepare_backend(release_id, ref)
        release, sha = checkout_release(backend_root, @config.fetch('backend').fetch('repository'), ref, release_id)
        @runner.deploy('bundle', 'config', 'set', '--local', 'deployment', 'true', config: @config, chdir: release)
        @runner.deploy('bundle', 'config', 'set', '--local', 'without', 'development test', config: @config,
                                                                                              chdir: release)
        @runner.deploy('bundle', 'install', config: @config, chdir: release, timeout: 1800)
        link_backend_shared(release)
        @rails.runner('Rails.application.eager_load!', release: release, timeout: 300)
        @rails.runner("ActiveRecord::Base.connection.execute('SELECT 1')", release: release, timeout: 300)
        [release, sha]
      end

      def prepare_frontend(release_id, ref)
        release, sha = checkout_release(frontend_root, @config.fetch('frontend').fetch('repository'), ref, release_id)
        @runner.deploy('npm', 'ci', config: @config, chdir: release, timeout: 1800)
        env = FrontendEnv.new(config: @config, logger: @logger)
        @runner.deploy(*@config.fetch('frontend').fetch('build_command'), config: @config, chdir: release,
                                                                        timeout: 1800, env: env.build_env)
        env.verify_build_output!(release: release,
                                 output_directory: @config.fetch('frontend').fetch('output_directory'), dry_run: false)
        [release, sha]
      end

      def checkout_release(root, repository, ref, release_id)
        release = File.join(root, 'releases', release_id)
        raise Error, "release directory already exists: #{release}" if File.exist?(release)

        @runner.run('install', '-d', '-o', deploy_user, '-g', deploy_user, '-m', '0755', root,
                    File.join(root, 'releases'), File.join(root, 'shared'))
        @runner.deploy('git', 'clone', '--no-checkout', repository, release, config: @config, timeout: 1800)
        @runner.deploy('git', 'fetch', '--prune', 'origin', ref, config: @config, chdir: release, timeout: 1800)
        sha = @runner.deploy('git', 'rev-parse', '--verify', 'FETCH_HEAD^{commit}', config: @config,
                                                                          chdir: release).stdout.strip
        raise Error, "could not resolve #{ref}" unless sha.match?(/\A[0-9a-f]{40}\z/i)

        @runner.deploy('git', 'checkout', '--detach', sha, config: @config, chdir: release)
        [release, sha]
      end

      def link_backend_shared(release)
        %w[log tmp].each do |name|
          shared = File.join(backend_root, 'shared', name)
          @runner.run('install', '-d', '-o', deploy_user, '-g', deploy_user, '-m', '0755', shared)
          FileUtils.rm_rf(File.join(release, name))
          FileUtils.ln_s(shared, File.join(release, name))
        end
      end

      def switch_pair!(backend_release, frontend_release, state)
        backend_manager.activate(backend_release)
        begin
          frontend_manager.activate(frontend_release)
          state[:switched] = true
        rescue StandardError
          backend_manager.activate(state[:previous_backend]) if state[:previous_backend]
          raise
        end
      end

      def rollback_after_failure(state, report)
        return unless state[:switched]

        @logger.puts('[ROLLBACK] restoring backend and frontend current symlinks; DB is not changed')
        backend_manager.activate(state[:previous_backend]) if state[:previous_backend]
        frontend_manager.activate(state[:previous_frontend]) if state[:previous_frontend]
        restart_services(allow_failure: true)
        reload_nginx(allow_failure: true)
        health_check(nil)
        report.assign(application_rollback: 'succeeded')
      rescue StandardError => rollback_error
        report.assign(application_rollback: 'failed', rollback_error: rollback_error.message)
      end

      def safe_disable_before_migration(state, report)
        return if state[:migration_started] || state[:switched]

        @maintenance.disable
        report.merge(:maintenance, disabled_at: Time.now.iso8601, disabled_after_safe_failure: true)
      rescue StandardError => e
        report.merge(:maintenance, disable_error: e.message)
      end

      def restart_services(allow_failure: false)
        @runner.run('systemctl', 'restart', release_config.fetch('api_service'), allow_failure: allow_failure)
        @runner.run('systemctl', 'restart', release_config.fetch('worker_service'), allow_failure: allow_failure)
        return if allow_failure

        @runner.run('systemctl', 'is-active', '--quiet', release_config.fetch('api_service'))
        @runner.run('systemctl', 'is-active', '--quiet', release_config.fetch('worker_service'))
      end

      def reload_nginx(allow_failure: false)
        @runner.run('nginx', '-t', allow_failure: allow_failure)
        @runner.run('systemctl', 'reload', 'nginx', allow_failure: allow_failure)
      end

      def health_check(report_path)
        @health.check!(health_url, host: @config.health_host, expected_json: { status: 'ready' },
                                   report_path: report_path)
      end

      def cleanup_releases(state)
        backend_manager.cleanup(protected_paths: [state[:previous_backend]].compact)
        frontend_manager.cleanup(protected_paths: [state[:previous_frontend]].compact)
      end

      def planned_steps
        %w[maintenance_enable database_backup pre_migration_snapshot backend_prepare frontend_prepare
           database_migration migration_verification release_switch service_restart nginx_reload
           readiness_health_check smoke_test maintenance_disable]
      end

      def step_outputs(name)
        case name
        when 'database_backup' then %w[database.dump database.dump.sha256]
        when 'pre_migration_snapshot' then %w[pre_migration_counts.json]
        when 'migration_verification' then %w[migration_report.json]
        when 'readiness_health_check' then %w[health_check_report.json]
        when 'smoke_test' then %w[smoke_test_report.json]
        else []
        end
      end

      def generate_release_id
        "#{Time.now.strftime('%Y%m%dT%H%M%S%z')}-#{SecureRandom.hex(3)}"
      end

      def current_release(root)
        link = File.join(root, 'current')
        File.symlink?(link) ? File.realpath(link) : nil
      rescue Errno::ENOENT
        nil
      end

      def release_basename(path)
        path && File.basename(path)
      end

      def backend_root
        @config.fetch('paths').fetch('rails_root')
      end

      def frontend_root
        @config.fetch('paths').fetch('frontend_root')
      end

      def deploy_user
        @config.fetch('deploy').fetch('user')
      end

      def release_config
        @config.fetch('release')
      end

      def health_url
        "http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/ready"
      end

      def backend_manager
        @backend_manager ||= ReleaseManager.new(root: backend_root, runner: @runner,
                                                keep: @config.fetch('backend').fetch('keep_releases'))
      end

      def frontend_manager
        @frontend_manager ||= ReleaseManager.new(root: frontend_root, runner: @runner,
                                                 keep: @config.fetch('frontend').fetch('keep_releases'))
      end
    end
  end
end
