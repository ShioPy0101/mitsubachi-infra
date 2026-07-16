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

    def check!(url, attempts: 10, delay: 2, dry_run: false)
      @logger.puts("[DRY-RUN] health check #{url}") if dry_run
      return true if dry_run

      attempts.times do |index|
        code = http_code(url)
        return true if code == 200

        @logger.puts("health check waiting #{index + 1}/#{attempts}: #{url} status=#{code || 'error'}")
        sleep delay
      end
      raise Error, "health check failed: #{url}"
    end

    private

    def http_code(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 5, open_timeout: 5) do |http|
        http.get(uri.request_uri).code.to_i
      end
    rescue StandardError
      nil
    end
  end
end
