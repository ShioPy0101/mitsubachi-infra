# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'timeout'
require 'uri'
require_relative 'errors'

module MitsubachiInfra
  class HealthCheck
    Result = Struct.new(:succeeded, :attempts, :elapsed_seconds, :status, :result, :body, keyword_init: true) do
      def to_h
        { succeeded: succeeded, attempts: attempts, elapsed_seconds: elapsed_seconds, status: status,
          result: result }
      end
    end

    def initialize(logger:)
      @logger = logger
    end

    def check!(url, attempts: 30, delay: 1, dry_run: false, host: nil, open_timeout: 2, read_timeout: 5,
               allow_redirect: false, expected_json: nil, report_path: nil)
      raise Error, 'health check Host header is required' if host.to_s.empty? && local_http_url?(url)

      if dry_run
        @logger.puts("[DRY-RUN] health check #{url}#{host ? " Host=#{host}" : ''}")
        return Result.new(succeeded: true, attempts: 0, elapsed_seconds: 0.0, result: 'dry_run')
      end

      started = monotonic
      last = nil
      attempts.times do |index|
        last = request(url, host: host, open_timeout: open_timeout, read_timeout: read_timeout)
        elapsed = (monotonic - started).round(3)
        if successful?(last, allow_redirect: allow_redirect, expected_json: expected_json)
          result = Result.new(succeeded: true, attempts: index + 1, elapsed_seconds: elapsed,
                              status: last[:status], result: last[:result], body: last[:body])
          @logger.puts("[OK] health check passed #{index + 1}/#{attempts}: status=#{last[:status]} elapsed_seconds=#{elapsed} url=#{url}")
          write_report(report_path, result)
          return result
        end

        @logger.puts("[WAIT] health check #{index + 1}/#{attempts}: result=#{last[:result]} url=#{url}")
        sleep delay if index + 1 < attempts
      end

      elapsed = (monotonic - started).round(3)
      result = Result.new(succeeded: false, attempts: attempts, elapsed_seconds: elapsed,
                          status: last && last[:status], result: last && last[:result], body: last && last[:body])
      write_report(report_path, result)
      raise Error, "health check failed after #{attempts} attempts: #{url} last_result=#{result.result}"
    end

    private

    def request(url, host:, open_timeout:, read_timeout:)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: read_timeout,
                                                    open_timeout: open_timeout) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request['Host'] = host if host
        http.request(request)
      end
      status = response.code.to_i
      { status: status, body: response.respond_to?(:body) ? response.body.to_s : '', result: "http_#{status}" }
    rescue Errno::ECONNREFUSED
      { result: 'connection_refused' }
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      { result: 'timeout' }
    rescue SocketError => e
      { result: 'dns_error', error: e.message }
    rescue StandardError => e
      { result: 'client_error', error: e.message }
    end

    def successful?(response, allow_redirect:, expected_json:)
      status = response[:status]
      return false unless status
      accepted = status.between?(200, 299) || (allow_redirect && status.between?(300, 399))
      return false unless accepted
      return true unless expected_json

      parsed = JSON.parse(response[:body])
      expected_json.all? do |key, value|
        expected_values = value.is_a?(Array) ? value : [value]
        expected_values.include?(parsed[key.to_s])
      end
    rescue JSON::ParserError
      false
    end

    def write_report(path, result)
      return if path.to_s.empty?

      File.write(path, JSON.pretty_generate(result.to_h) + "\n", mode: 'w', perm: 0o640)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def local_http_url?(url)
      uri = URI(url)
      uri.scheme == 'http' && %w[127.0.0.1 localhost].include?(uri.host)
    rescue URI::InvalidURIError
      false
    end
  end
end
