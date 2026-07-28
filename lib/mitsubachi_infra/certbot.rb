# frozen_string_literal: true

require 'json'
require 'resolv'
require 'time'
require_relative 'errors'

module MitsubachiInfra
  class Certbot
    DEFAULT_ACME_ROOT = '/var/lib/mitsubachi/acme'
    DEFAULT_LIVE_ROOT = '/etc/letsencrypt/live'
    RENEW_HOOK = '/etc/letsencrypt/renewal-hooks/deploy/mitsubachi-nginx-reload'

    def initialize(config:, runner:, nginx:, health:, logger: $stderr, resolver: Resolv::DNS.new,
                   letsencrypt_live: DEFAULT_LIVE_ROOT)
      @config = config
      @runner = runner
      @nginx = nginx
      @health = health
      @logger = logger
      @resolver = resolver
      @letsencrypt_live = letsencrypt_live
    end

    def check(json: false)
      validate_public_config!
      snapshot = status_data(include_health: false)
      print_status(snapshot, json: json)
      unresolved = unresolved_hosts(snapshot[:dns])
      raise Error, "DNS does not resolve: #{unresolved.join(', ')}" unless unresolved.empty?

      @logger.puts('DNS resolution passed.')
      @logger.puts('External TCP 80/443 reachability cannot be fully verified from this host.')
      @logger.puts('Check router port forwarding and upstream firewall.')
      snapshot
    end

    def enable(staging: false)
      validate_public_config!
      unless @runner.dry_run
        dns = dns_status
        raise Error, "DNS does not resolve: #{unresolved_hosts(dns).join(', ')}" unless unresolved_hosts(dns).empty?
      end

      check_local_listeners
      @runner.run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', acme_root)
      @nginx.install(mode: 'public_http_challenge')
      certificate_hosts.each { |host| obtain_certificate(host, staging: staging) }
      certificate_hosts.each { |host| verify_certificate!(host, staging: staging) }
      install_renew_hook
      enable_certbot_timer
      @nginx.install(mode: 'public_https')
      https_health_check
      print_status(status_data, json: false)
    end

    def renew
      validate_public_config!
      @runner.run('certbot', 'renew', timeout: 1800)
      certificate_hosts.each { |host| verify_certificate!(host, staging: false, allow_staging: true) }
      @nginx.test!
      @nginx.reload
      https_health_check
      print_status(status_data, json: false)
    end

    def status(json: false)
      validate_public_config!
      print_status(status_data, json: json)
    end

    private

    def validate_public_config!
      raise Error, 'deployment_mode must be public' unless @config.public?

      @config.validate!
      raise Error, 'https.email is required in public mode' if @config.fetch('https').fetch('email').to_s.empty?
    end

    def certificate_hosts
      @config.certificate_domains
    end

    def acme_root
      @config.fetch('https').fetch('acme_webroot', DEFAULT_ACME_ROOT)
    end

    def cert_path(host)
      File.join(@letsencrypt_live, host, 'fullchain.pem')
    end

    def key_path(host)
      File.join(@letsencrypt_live, host, 'privkey.pem')
    end

    def obtain_certificate(host, staging:)
      if reusable_certificate?(host, staging: staging)
        @logger.puts("[CERTBOT] reusing certificate for #{host}")
        return
      end

      args = [
        'certbot', 'certonly',
        '--webroot',
        '--webroot-path', acme_root,
        '--non-interactive',
        '--agree-tos',
        '--email', @config.fetch('https').fetch('email'),
        '--cert-name', host,
        '-d', host
      ]
      args << '--staging' if staging
      @runner.run(*args, timeout: 1800)
    rescue Error
      @logger.puts('[CERTBOT] certificate obtain failed; keeping HTTP ACME challenge configuration')
      raise
    end

    def reusable_certificate?(host, staging:)
      return false if staging

      verify_certificate!(host, staging: false)
      true
    rescue Error
      false
    end

    def verify_certificate!(host, staging:, allow_staging: false)
      return @logger.puts("[DRY-RUN] verify certificate #{host} staging=#{staging}") if @runner.dry_run

      raise Error, "certificate files are missing: #{host}" unless File.exist?(cert_path(host)) && File.exist?(key_path(host))

      run_ok!('openssl', 'x509', '-checkend', '0', '-noout', '-in', cert_path(host),
              error: "certificate is expired: #{host}")
      san = openssl_stdout('x509', '-in', cert_path(host), '-noout', '-ext', 'subjectAltName')
      raise Error, "certificate SAN does not include #{host}" unless san.include?("DNS:#{host}")

      issuer = openssl_stdout('x509', '-in', cert_path(host), '-noout', '-issuer')
      if staging
        raise Error, "expected staging certificate for #{host}" unless staging_issuer?(issuer)
      elsif staging_issuer?(issuer) && !allow_staging
        raise Error, "staging certificate cannot be reused for production: #{host}"
      end

      cert_modulus = openssl_stdout('x509', '-noout', '-modulus', '-in', cert_path(host))
      key_modulus = openssl_stdout('rsa', '-noout', '-modulus', '-in', key_path(host))
      raise Error, "certificate and private key do not match: #{host}" unless cert_modulus == key_modulus
    end

    def run_ok!(*command, error:)
      result = @runner.run(*command, allow_failure: true)
      raise Error, error unless result.success?

      result
    end

    def openssl_stdout(*args)
      @runner.run('openssl', *args).stdout
    end

    def staging_issuer?(issuer)
      issuer.downcase.include?('staging') || issuer.downcase.include?('fake le')
    end

    def dns_status
      certificate_hosts.to_h do |host|
        a = dns_records(host, Resolv::DNS::Resource::IN::A)
        aaaa = dns_records(host, Resolv::DNS::Resource::IN::AAAA)
        [host, { 'A' => a, 'AAAA' => aaaa, 'warning' => aaaa.empty? ? nil : ipv6_warning(host, aaaa) }]
      end
    end

    def dns_records(host, type)
      @resolver.getresources(host, type).map { |record| record.address.to_s }
    rescue Resolv::ResolvError, SystemCallError
      []
    end

    def ipv6_warning(host, addresses)
      "AAAA records exist for #{host}: #{addresses.join(', ')}. Ensure IPv6 reaches this server before certbot HTTP-01."
    end

    def unresolved_hosts(dns)
      dns.select { |_host, records| records.fetch('A').empty? && records.fetch('AAAA').empty? }.keys
    end

    def check_local_listeners
      result = @runner.run('ss', '-ltnp', allow_failure: true)
      return unless result.success?

      if result.stdout.match?(/:(80|443)\b.*caddy/i)
        raise Error, 'Caddy appears to be listening on 80/443; stop/disable Caddy before enabling Nginx HTTPS'
      end

      @logger.puts('[HTTPS] local 80/443 listener check completed')
    end

    def install_renew_hook
      hook = <<~SH
        #!/bin/sh
        set -eu
        nginx -t
        systemctl reload nginx
      SH
      if @runner.dry_run
        @logger.puts("[DRY-RUN] write #{RENEW_HOOK}")
        return
      end

      tmp = "/tmp/mitsubachi-renew-hook-#{$PROCESS_ID}"
      File.write(tmp, hook)
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0755', tmp, RENEW_HOOK)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def enable_certbot_timer
      @runner.run('systemctl', 'enable', '--now', 'certbot.timer', allow_failure: true)
    end

    def https_health_check
      @health.check!('http://127.0.0.1/', host: @config.frontend_host, dry_run: @runner.dry_run)
      %w[live ready].each do |state|
        @health.check!("http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/#{state}",
                       host: @config.api_host, dry_run: @runner.dry_run)
      end
    end

    def status_data(include_health: true)
      {
        deployment_mode: @config.fetch('deployment_mode'),
        frontend_hostname: @config.frontend_host,
        api_hostname: @config.api_host,
        dns: dns_status,
        certificates: certificate_hosts.to_h { |host| [host, certificate_status(host)] },
        nginx_config: @nginx.test_result.success?,
        nginx_service: @runner.run('systemctl', 'is-active', 'nginx', allow_failure: true).stdout.strip,
        certbot_timer: timer_status,
        local_live_health: include_health ? local_api_health_result('live') : nil,
        local_ready_health: include_health ? local_api_health_result('ready') : nil
      }
    end

    def certificate_status(host)
      return { path: cert_path(host), present: false } unless File.exist?(cert_path(host))

      text = @runner.run('openssl', 'x509', '-in', cert_path(host), '-noout', '-subject', '-issuer', '-dates',
                         '-ext', 'subjectAltName', allow_failure: true).stdout
      not_after = text[/notAfter=(.+)$/, 1]
      expires_at = Time.parse(not_after) if not_after
      {
        path: cert_path(host),
        present: true,
        subject: text[/subject=(.+)$/, 1],
        issuer: text[/issuer=(.+)$/, 1],
        san: text.scan(/DNS:([^,\s]+)/).flatten,
        not_before: text[/notBefore=(.+)$/, 1],
        not_after: not_after,
        remaining_days: expires_at ? ((expires_at - Time.now) / 86_400).floor : nil,
        staging: staging_issuer?(text)
      }
    rescue StandardError
      { path: cert_path(host), present: true, error: 'failed to inspect certificate' }
    end

    def timer_status
      {
        enabled: @runner.run('systemctl', 'is-enabled', 'certbot.timer', allow_failure: true).success?,
        active: @runner.run('systemctl', 'is-active', 'certbot.timer', allow_failure: true).success?
      }
    end

    def local_api_health_result(state)
      url = "http://127.0.0.1:#{@config.fetch('ports').fetch('rails')}#{@config.fetch('backend').fetch('health_path')}/#{state}"
      @runner.run('curl', '-fsS', '-o', '/dev/null', '-H', "Host: #{@config.api_host}", url,
                  allow_failure: true).success?
    end

    def print_status(data, json:)
      if json
        puts JSON.pretty_generate(data)
      else
        @logger.puts("deployment_mode: #{data[:deployment_mode]}")
        @logger.puts("frontend_hostname: #{data[:frontend_hostname]}")
        @logger.puts("api_hostname: #{data[:api_hostname]}")
        data[:dns].each do |host, records|
          a = records['A'].empty? ? '(none)' : records['A'].join(',')
          aaaa = records['AAAA'].empty? ? '(none)' : records['AAAA'].join(',')
          @logger.puts("dns #{host} A=#{a} AAAA=#{aaaa}")
          @logger.puts("warning: #{records['warning']}") if records['warning']
        end
        data[:certificates].each do |host, cert|
          @logger.puts("certificate #{host}: path=#{cert[:path]} present=#{cert[:present]} issuer=#{cert[:issuer]} not_after=#{cert[:not_after]} remaining_days=#{cert[:remaining_days]}")
        end
        @logger.puts("nginx_config: #{data[:nginx_config]}")
        @logger.puts("nginx_service: #{data[:nginx_service]}")
        @logger.puts("certbot.timer enabled=#{data[:certbot_timer][:enabled]} active=#{data[:certbot_timer][:active]}")
      end
    end
  end
end
