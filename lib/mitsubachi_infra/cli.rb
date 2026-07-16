# frozen_string_literal: true

require 'optparse'
require_relative 'certbot'
require_relative 'command_runner'
require_relative 'configuration'
require_relative 'deploy_user'
require_relative 'deployment/backend'
require_relative 'deployment/frontend'
require_relative 'deployment/rollback'
require_relative 'errors'
require_relative 'health_check'
require_relative 'installer'
require_relative 'lock'
require_relative 'nginx'
require_relative 'production'
require_relative 'status'
require_relative 'systemd'

module MitsubachiInfra
  class CLI
    def initialize(argv, repo_root:)
      @argv = argv.dup
      @repo_root = repo_root
      @options = { dry_run: false, config: Configuration::CONFIG_PATH }
    end

    def run
      parse_global!
      command = @argv.shift || 'help'
      @config = Configuration.new(@options[:config])
      @runner = CommandRunner.new(logger: $stderr, dry_run: @options[:dry_run])
      case command
      when 'bootstrap' then locked { production.bootstrap }
      when 'configure' then locked { production.bootstrap }
      when 'production-check' then production.production_check
      when 'doctor' then production.doctor
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
      when 'https' then https
      when 'help', '--help', '-h' then puts usage
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
      locked do
        Installer.new(config: @config, runner: @runner, repo_root: @repo_root).install(
          interactive: local[:interactive],
          remove_nginx_default_site: local[:remove_nginx_default_site]
        )
      end
    end

    def deploy
      target = @argv.first && !@argv.first.start_with?('-') ? @argv.shift : 'all'
      opts = {}
      OptionParser.new do |parser|
        parser.on('--ref REF') { |v| opts[:ref] = v }
        parser.on('--backend-ref REF') { |v| opts[:backend_ref] = v }
        parser.on('--frontend-ref REF') { |v| opts[:frontend_ref] = v }
      end.parse!(@argv)
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

    def rollback
      target = @argv.first && !@argv.first.start_with?('-') ? @argv.shift : 'all'
      OptionParser.new.parse!(@argv)
      if production_configured?
        locked { production.rollback(target) }
        return
      end
      locked { Deployment::Rollback.new(config: @config, runner: @runner, systemd: Systemd.new(runner: @runner), health: HealthCheck.new(logger: $stderr)).rollback(target) }
    end

    def status
      opts = { json: false }
      OptionParser.new { |parser| parser.on('--json') { opts[:json] = true } }.parse!(@argv)
      Status.new(config: @config, runner: @runner, systemd: Systemd.new(runner: @runner),
                 health: HealthCheck.new(logger: $stderr)).print(json: opts[:json])
    end

    def https
      sub = @argv.shift || 'status'
      opts = { staging: false }
      OptionParser.new { |parser| parser.on('--staging') { opts[:staging] = true } }.parse!(@argv)
      nginx = Nginx.new(config: @config, runner: @runner, repo_root: @repo_root)
      certbot = Certbot.new(config: @config, runner: @runner, nginx: nginx, health: HealthCheck.new(logger: $stderr))
      case sub
      when 'check' then certbot.check
      when 'enable' then locked { certbot.enable(staging: opts[:staging]) }
      when 'renew' then locked { certbot.renew }
      when 'status' then certbot.status
      else raise ValidationError, 'https command must be check, enable, renew, or status'
      end
    end

    def usage
      <<~USAGE
        Usage:
          mitsubachi-infra bootstrap [--dry-run]
          mitsubachi-infra configure [--dry-run]
          mitsubachi-infra install [--interactive] [--remove-nginx-default-site] [--dry-run]
          mitsubachi-infra deploy [all|backend|frontend] [--ref REF] [--dry-run]
          mitsubachi-infra deploy-backend [--dry-run]
          mitsubachi-infra deploy-frontend [--dry-run]
          mitsubachi-infra redeploy [--dry-run]
          mitsubachi-infra rollback [all|backend|frontend] [--dry-run]
          mitsubachi-infra rollback-backend [--dry-run]
          mitsubachi-infra rollback-frontend [--dry-run]
          mitsubachi-infra production-check [--dry-run]
          mitsubachi-infra doctor [--dry-run]
          mitsubachi-infra mail-test --to ADDRESS [--dry-run]
          mitsubachi-infra status [--json]
          mitsubachi-infra https check|enable|renew|status [--staging] [--dry-run]
      USAGE
    end

    def mail_test
      opts = {}
      OptionParser.new { |parser| parser.on('--to ADDRESS') { |v| opts[:to] = v } }.parse!(@argv)
      production.mail_test(to: opts[:to])
    end

    def production
      @production ||= Production.new(config: @config, repo_root: @repo_root, runner: @runner, logger: $stderr)
    end

    def deploy_production_alias(target)
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

    def locked(&block)
      return yield if @runner.dry_run

      Lock.with(&block)
    end
  end
end
