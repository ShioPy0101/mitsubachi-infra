# frozen_string_literal: true

require 'optparse'
require 'fileutils'
require 'json'
require_relative 'certbot'
require_relative 'command_runner'
require_relative 'configuration'
require_relative 'deploy_user'
require_relative 'deployment/backend'
require_relative 'deployment/frontend'
require_relative 'deployment/rollback'
require_relative 'deployment/release'
require_relative 'deployment/maintenance'
require_relative 'deployment/smoke_tester'
require_relative 'errors'
require_relative 'frontend_env'
require_relative 'health_check'
require_relative 'installer'
require_relative 'lock'
require_relative 'nginx'
require_relative 'postgresql_wal_archive'
require_relative 'production'
require_relative 'status'
require_relative 'systemd'

module MitsubachiInfra
  class CLI
    def initialize(argv, repo_root:)
      @original_argv = argv.dup
      @argv = argv.dup
      @repo_root = repo_root
      @options = { dry_run: false, config: Configuration::CONFIG_PATH }
    end

    def run
      parse_global!
      command = @argv.shift || 'help'
      if %w[help --help -h].include?(command)
        puts usage
        return 0
      end
      require_root_for!(command, @argv)
      @config = Configuration.new(@options[:config], validate: false)
      @runner = CommandRunner.new(logger: $stderr, dry_run: @options[:dry_run])
      case command
      when 'bootstrap'
        @config.validate!
        locked { production.bootstrap }
      when 'configure'
        @config.validate!
        locked { production.bootstrap }
      when 'production-check'
        @config.validate!
        production.production_check
      when 'doctor'
        doctor
      when 'mail-test' then mail_test
      when 'redeploy' then deploy_production_alias('all')
      when 'deploy-backend' then deploy_production_alias('backend')
      when 'deploy-frontend' then deploy_production_alias('frontend')
      when 'rollback-backend' then locked { production.rollback('backend') }
      when 'rollback-frontend' then locked { production.rollback('frontend') }
      when 'caddy-install', 'caddy-configure'
        raise ValidationError, 'Caddy commands are retired; use Nginx + Certbot install/https commands'
      when 'install' then install
      when 'deploy' then deploy
      when 'rollback' then rollback
      when 'status' then status
      when 'config' then config
      when 'https' then https
      when 'postgres' then postgres
      when 'maintenance' then maintenance
      when 'smoke-test' then smoke_test
      else raise ValidationError, "unknown command: #{command}"
      end
      0
    rescue Error, OptionParser::ParseError => e
      warn "error: #{e.message}"
      1
    end

    private

    def parse_global!
      parser = OptionParser.new do |opts|
        opts.on('--config PATH') { |v| @options[:config] = v }
        opts.on('--dry-run') { @options[:dry_run] = true }
      end
      parser.order!(@argv)
    end

    def install
      local = { interactive: false, remove_nginx_default_site: nil }
      OptionParser.new do |opts|
        opts.on('--interactive') { local[:interactive] = true }
        opts.on('--remove-nginx-default-site') { local[:remove_nginx_default_site] = true }
      end.parse!(@argv)
      result = nil
      locked do
        result = Installer.new(config: @config, runner: @runner, repo_root: @repo_root).install(
          interactive: local[:interactive],
          remove_nginx_default_site: local[:remove_nginx_default_site]
        )
      end
      exec_after_self_update(result) if result && result[:reexec]
    end

    def deploy
      @config.validate!
      target = @argv.first && !@argv.first.start_with?('-') ? @argv.shift : 'all'
      opts = {}
      OptionParser.new do |parser|
        parser.on('--all') { target = 'all' }
        parser.on('--backend') { target = 'backend' }
        parser.on('--frontend') { target = 'frontend' }
        parser.on('--ref REF') { |v| opts[:ref] = v }
        parser.on('--backend-ref REF') { |v| opts[:backend_ref] = v }
        parser.on('--frontend-ref REF') { |v| opts[:frontend_ref] = v }
        parser.on('--dry-run') do
          @options[:dry_run] = true
          @runner.dry_run = true
        end
      end.parse!(@argv)
      if target == 'release'
        Deployment::Release.new(config: @config, runner: @runner, logger: $stderr)
                           .deploy(backend_ref: opts[:backend_ref], frontend_ref: opts[:frontend_ref])
        return
      end
      locked do
        if production_configured?
          production.deploy(target, backend_ref: opts[:backend_ref] || opts[:ref],
                                    frontend_ref: opts[:frontend_ref] || opts[:ref])
          next
        end
        systemd = Systemd.new(runner: @runner)
        health = HealthCheck.new(logger: $stderr)
        DeployUser.new(config: @config, runner: @runner).ensure!
        case target
        when 'backend' then Deployment::Backend.new(config: @config, runner: @runner, systemd: systemd,
                                                    health: health).deploy(ref: opts[:ref])
        when 'frontend' then Deployment::Frontend.new(config: @config, runner: @runner,
                                                      health: health).deploy(ref: opts[:ref])
        when 'all'
          Deployment::Backend.new(config: @config, runner: @runner, systemd: systemd,
                                  health: health).deploy(ref: opts[:backend_ref] || opts[:ref])
          Deployment::Frontend.new(config: @config, runner: @runner,
                                   health: health).deploy(ref: opts[:frontend_ref] || opts[:ref])
        else raise ValidationError, 'deploy target must be all, backend, or frontend'
        end
      end
    end

    def maintenance
      action = @argv.shift || 'status'
      OptionParser.new.parse!(@argv)
      @config.validate!
      manager = Deployment::Maintenance.new(path: @config.fetch('release').fetch('maintenance_flag'),
                                             runner: @runner, logger: $stderr)
      case action
      when 'enable' then locked { manager.enable }
      when 'disable' then locked { manager.disable }
      when 'status'
        puts(manager.enabled? ? 'enabled' : 'disabled')
      else raise ValidationError, 'maintenance command must be enable, disable, or status'
      end
    end

    def smoke_test
      environment = @argv.shift
      raise ValidationError, 'smoke-test target must be production' unless environment == 'production'

      opts = {}
      OptionParser.new { |parser| parser.on('--release-id ID') { |value| opts[:release_id] = value } }.parse!(@argv)
      raise ValidationError, '--release-id is required' if opts[:release_id].to_s.empty?
      unless opts[:release_id].match?(/\A[A-Za-z0-9][A-Za-z0-9+_.-]*\z/) && !opts[:release_id].include?('..')
        raise ValidationError, '--release-id contains unsafe characters'
      end

      @config.validate!
      root = @config.fetch('release').fetch('backup_root')
      directory = File.join(root, opts[:release_id])
      raise ValidationError, "release report directory is missing: #{directory}" unless File.directory?(directory)

      output = File.join(directory, 'smoke_test_report.json')
      Deployment::SmokeTester.new(config: @config, runner: @runner, logger: $stderr)
                             .run!(release_id: opts[:release_id], output: output)
      update_smoke_release_report(directory, output)
    end

    def update_smoke_release_report(directory, output)
      path = File.join(directory, 'release.json')
      return unless File.file?(path)

      data = JSON.parse(File.read(path))
      data['smoke_test'] = { 'succeeded' => true, 'report_path' => output }
      temp = "#{path}.tmp.#{$PROCESS_ID}"
      File.write(temp, JSON.pretty_generate(data) + "\n", mode: 'w', perm: 0o640)
      File.rename(temp, path)
    rescue JSON::ParserError => e
      raise Error, "release report is invalid JSON: #{e.message}"
    ensure
      FileUtils.rm_f(temp) if defined?(temp) && temp
    end

    def rollback
      @config.validate!
      target = @argv.first && !@argv.first.start_with?('-') ? @argv.shift : 'all'
      OptionParser.new.parse!(@argv)
      if production_configured?
        locked { production.rollback(target) }
        return
      end
      locked { Deployment::Rollback.new(config: @config, runner: @runner, systemd: Systemd.new(runner: @runner), health: HealthCheck.new(logger: $stderr)).rollback(target) }
    end

    def status
      @config.validate!
      opts = { json: false }
      OptionParser.new { |parser| parser.on('--json') { opts[:json] = true } }.parse!(@argv)
      Status.new(config: @config, runner: @runner, systemd: Systemd.new(runner: @runner),
                 health: HealthCheck.new(logger: $stderr)).print(json: opts[:json])
    end

    def config
      sub = @argv.shift || 'show'
      raise ValidationError, 'config command must be show' unless sub == 'show'

      @config.validate!
      frontend_env = FrontendEnv.new(config: @config, logger: $stderr)
      puts "Frontend URL: #{@config.public? ? "https://#{@config.frontend_host}" : "http://#{@config.fetch('server_ip')}"}"
      puts "API URL: #{@config.public? ? "https://#{@config.api_host}" : "http://#{@config.fetch('server_ip')}"}"
      puts "Frontend env file: #{@config.fetch('paths').fetch('frontend_env')}"
      puts "VITE_API_BASE_URL: #{frontend_env.vite_api_base_url.empty? ? '(missing)' : frontend_env.vite_api_base_url}"
      frontend_env.masked_entries.sort.each do |key, value|
        next if key == FrontendEnv::VITE_API_BASE_URL

        puts "#{key}: #{value}"
      end
    end

    def doctor
      @config.validate!
      target = @argv.first && !@argv.first.start_with?('-') ? @argv.shift : nil
      OptionParser.new.parse!(@argv)
      case target
      when 'frontend' then production.doctor_frontend
      when nil then production.doctor
      else raise ValidationError, 'doctor target must be frontend'
      end
    end

    def https
      sub = @argv.shift || 'status'
      opts = { staging: false, json: false }
      OptionParser.new do |parser|
        parser.on('--staging') { opts[:staging] = true }
        parser.on('--json') { opts[:json] = true }
        parser.on('--dry-run') do
          @options[:dry_run] = true
          @runner.dry_run = true
        end
      end.parse!(@argv)
      @config.validate!
      nginx = Nginx.new(config: @config, runner: @runner, repo_root: @repo_root)
      certbot = Certbot.new(config: @config, runner: @runner, nginx: nginx, health: HealthCheck.new(logger: $stderr),
                            logger: $stderr)
      case sub
      when 'check' then certbot.check(json: opts[:json])
      when 'enable' then locked { certbot.enable(staging: opts[:staging]) }
      when 'renew' then locked { certbot.renew }
      when 'status' then certbot.status(json: opts[:json])
      else raise ValidationError, 'https command must be check, enable, renew, or status'
      end
    end

    def postgres
      sub = @argv.shift
      raise ValidationError, 'postgres command must be wal-archive or base-backup' unless %w[wal-archive base-backup].include?(sub)

      action = @argv.shift || 'status'
      opts = { verify: false, json: false, yes: false, root_directory: nil, timeout: nil, retention_days: nil,
               minimum: nil, checkpoint: 'fast' }
      OptionParser.new do |parser|
        parser.on('--verify') { opts[:verify] = true }
        parser.on('--json') { opts[:json] = true }
        parser.on('--yes') { opts[:yes] = true }
        parser.on('--root-dir PATH') { |v| opts[:root_directory] = v }
        parser.on('--timeout SECONDS') { |v| opts[:timeout] = Integer(v) }
        parser.on('--retention-days DAYS') { |v| opts[:retention_days] = Integer(v) }
        parser.on('--minimum COUNT') { |v| opts[:minimum] = Integer(v) }
        parser.on('--checkpoint MODE') { |v| opts[:checkpoint] = v }
        parser.on('--dry-run') do
          @options[:dry_run] = true
          @runner.dry_run = true
        end
      end.parse!(@argv)
      @config.validate!
      wal = PostgreSQLWalArchive.new(config: @config, runner: @runner, logger: $stderr,
                                     root_directory: opts[:root_directory])
      case sub
      when 'wal-archive'
        case action
        when 'enable', 'configure' then locked { wal.enable(verify: opts[:verify], yes: opts[:yes]) }
        when 'disable' then locked { wal.disable(yes: opts[:yes]) }
        when 'test', 'verify' then locked { wal.test(timeout: opts[:timeout] || PostgreSQLWalArchive::DEFAULT_TEST_TIMEOUT) }
        when 'status' then wal.status(json: opts[:json])
        else raise ValidationError, 'postgres wal-archive command must be enable, disable, status, or test'
        end
      when 'base-backup'
        case action
        when 'create' then locked { wal.create_base_backup(checkpoint: opts[:checkpoint], yes: opts[:yes]) }
        when 'list' then wal.list_base_backups(json: opts[:json])
        when 'prune'
          locked do
            wal.prune_base_backups(retention_days: opts[:retention_days], minimum: opts[:minimum],
                                   dry_run: @runner.dry_run, yes: opts[:yes])
          end
        else raise ValidationError, 'postgres base-backup command must be create, list, or prune'
        end
      end
    end

    def usage
      <<~USAGE
        Usage: mitsubachi-infra [--config PATH] [--dry-run] COMMAND [OPTIONS]

        Setup and configuration:
          mitsubachi-infra install [--interactive] [--remove-nginx-default-site]
          mitsubachi-infra bootstrap
          mitsubachi-infra configure

        Application deployment:
          mitsubachi-infra deploy [all|backend|frontend] [--ref REF]
          mitsubachi-infra deploy release --backend-ref REF --frontend-ref REF
          mitsubachi-infra rollback [all|backend|frontend]
          mitsubachi-infra maintenance enable|disable|status
          mitsubachi-infra smoke-test production --release-id ID

        Inspection and operations:
          mitsubachi-infra status [--json]
          mitsubachi-infra config show
          mitsubachi-infra doctor [frontend]
          mitsubachi-infra production-check
          mitsubachi-infra mail-test --to ADDRESS
          mitsubachi-infra https check
          mitsubachi-infra https enable [--staging]
          mitsubachi-infra https renew
          mitsubachi-infra https status [--json]

        PostgreSQL backup:
          mitsubachi-infra postgres wal-archive enable [--verify] [--root-dir PATH] [--yes]
          mitsubachi-infra postgres wal-archive disable [--yes]
          mitsubachi-infra postgres wal-archive status [--json]
          mitsubachi-infra postgres wal-archive test [--timeout SECONDS]
          mitsubachi-infra postgres base-backup create [--checkpoint fast|spread] [--yes]
          mitsubachi-infra postgres base-backup list [--json]
          mitsubachi-infra postgres base-backup prune [--retention-days DAYS] [--minimum COUNT] [--yes]

        Global options must precede COMMAND. Use --dry-run before a mutating command.
      USAGE
    end

    def mail_test
      @config.validate!
      opts = {}
      OptionParser.new { |parser| parser.on('--to ADDRESS') { |v| opts[:to] = v } }.parse!(@argv)
      production.mail_test(to: opts[:to])
    end

    def production
      @production ||= Production.new(config: @config, repo_root: @repo_root, runner: @runner, logger: $stderr)
    end

    def deploy_production_alias(target)
      @config.validate!
      opts = {}
      OptionParser.new do |parser|
        parser.on('--ref REF') { |v| opts[:ref] = v }
        parser.on('--backend-ref REF') { |v| opts[:backend_ref] = v }
        parser.on('--frontend-ref REF') { |v| opts[:frontend_ref] = v }
      end.parse!(@argv)
      locked do
        production.deploy(target, backend_ref: opts[:backend_ref] || opts[:ref],
                                  frontend_ref: opts[:frontend_ref] || opts[:ref])
      end
    end

    def production_configured?
      @config.fetch('server')['server_id'].to_s != ''
    end

    def require_root_for!(command, argv)
      return if Process.euid.zero?

      return unless root_required?(command, argv)

      hint = command == 'https' ? "sudo mitsubachi-infra https #{argv.first || 'enable'}" : "sudo mitsubachi-infra #{command}"
      raise ValidationError, "#{command} must be run as root\nhint: #{hint}"
    end

    def root_required?(command, argv)
      return true if %w[install bootstrap configure deploy deploy-backend deploy-frontend redeploy rollback rollback-backend rollback-frontend mail-test smoke-test].include?(command)
      return true if command == 'maintenance' && %w[enable disable].include?(argv.first || 'status')
      return true if command == 'postgres' && %w[wal-archive base-backup].include?(argv.first)
      return false unless command == 'https'

      %w[enable renew].include?(argv.first || 'status')
    end

    def locked(&block)
      return yield if @runner.dry_run

      Lock.with(&block)
    end

    def exec_after_self_update(result)
      executable = result.fetch(:executable)
      warn "info: CLI self-update installed #{result[:release]}; re-executing #{executable}"
      ENV[Installer::SELF_UPDATE_ENV] = '1'
      exec(executable, *@original_argv)
    end
  end
end
