# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'timeout'
require_relative 'errors'

module MitsubachiInfra
  class HealthCheck
    def initialize(logger:)
      @logger = logger
    end

    def check!(url, attempts: 30, delay: 1, dry_run: false, host: nil, open_timeout: 2, read_timeout: 5,
               allow_redirect: false)
      raise Error, 'health check Host header is required' if host.to_s.empty? && local_http_url?(url)

      @logger.puts("[DRY-RUN] health check #{url}#{host ? " Host=#{host}" : ''}") if dry_run
      return true if dry_run

      attempts.times do |index|
        code = http_code(url, host: host, open_timeout: open_timeout, read_timeout: read_timeout)
        return true if successful_status?(code, allow_redirect: allow_redirect)
        if code == 403
          raise Error, [
            'Rails returned HTTP 403.',
            'Check the health-check Host header and Rails ALLOWED_HOSTS/config.hosts.',
            "url=#{url}",
            "host=#{host || '(none)'}"
          ].join("\n")
        end

        @logger.puts("health check waiting #{index + 1}/#{attempts}: #{url} status=#{code || 'error'}")
        sleep delay
      end
      raise Error, "health check failed: #{url}"
    end

    private

    def successful_status?(code, allow_redirect:)
      return false unless code
      return true if code.between?(200, 299)

      allow_redirect && code.between?(300, 399)
    end

    def http_code(url, host:, open_timeout:, read_timeout:)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: read_timeout,
                                          open_timeout: open_timeout) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request['Host'] = host if host
        http.request(request).code.to_i
      end
    rescue StandardError
      nil
    end

    def local_http_url?(url)
      uri = URI(url)
      uri.scheme == 'http' && %w[127.0.0.1 localhost].include?(uri.host)
    rescue URI::InvalidURIError
      false
    end
  end
end
