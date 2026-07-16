# frozen_string_literal: true

require 'resolv'
require_relative 'errors'

module MitsubachiInfra
  class Certbot
    ACME_ROOT = '/var/lib/mitsubachi/acme'

    def initialize(config:, runner:, nginx:, health:)
      @config = config
      @runner = runner
      @nginx = nginx
      @health = health
    end

    def check
      validate_public_config!
      host = @config.fetch('https').fetch('host')
      addresses = Resolv.getaddresses(host)
      raise Error, "DNS does not resolve: #{host}" if addresses.empty?

      @runner.run('certbot', 'certificates', allow_failure: true)
    end

    def enable(staging: false)
      validate_public_config!
      host = @config.fetch('https').fetch('host')
      email = @config.fetch('https').fetch('email')
      @runner.run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', ACME_ROOT)
      @nginx.install(mode: 'public_http_challenge')
      args = ['certbot', 'certonly', '--webroot', '-w', ACME_ROOT, '-d', host, '--email', email, '--agree-tos',
              '--non-interactive']
      args << '--staging' if staging
      @runner.run(*args, timeout: 1800)
      cert = "/etc/letsencrypt/live/#{host}/fullchain.pem"
      key = "/etc/letsencrypt/live/#{host}/privkey.pem"
      unless @runner.dry_run || (File.exist?(cert) && File.exist?(key))
        raise Error,
              'certificate files are missing after certbot'
      end

      @nginx.install(mode: 'public_https')
    end

    def renew
      @runner.run('certbot', 'renew', '--deploy-hook', 'nginx -t && systemctl reload nginx', timeout: 1800)
    end

    def status
      @runner.run('certbot', 'certificates', allow_failure: true)
    end

    private

    def validate_public_config!
      raise Error, 'deployment_mode must be public' unless @config.public?

      @config.validate!
    end
  end
end
