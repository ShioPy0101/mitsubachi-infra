# frozen_string_literal: true

require "ipaddr"
require "yaml"
require_relative "errors"

module MitsubachiInfra
  class Configuration
    CONFIG_PATH = "/etc/mitsubachi/config.yml"
    DEFAULT = {
      "deployment_mode" => "lan",
      "server_ip" => "192.168.1.50",
      "lan_cidr" => "192.168.1.0/24",
      "deploy" => {
        "user" => "deploy",
        "home" => "/home/deploy",
        "app_root" => "/var/www/mitsubachi"
      },
      "backend" => {
        "repository" => "git@github.com:ShioPy0101/mitsubachi-ruby.git",
        "ref" => "main",
        "keep_releases" => 5,
        "health_path" => "/api/health"
      },
      "frontend" => {
        "repository" => "git@github.com:ShioPy0101/mitsubachi-front.git",
        "ref" => "main",
        "keep_releases" => 5,
        "build_command" => %w[npm run build],
        "output_directory" => "dist"
      },
      "https" => {
        "host" => nil,
        "email" => nil,
        "staging" => false,
        "challenge" => "http-01"
      }
    }.freeze

    attr_reader :path, :data

    def initialize(path = CONFIG_PATH, data: nil)
      @path = path
      @data = deep_merge(DEFAULT, data || load_file(path))
      validate!
    end

    def [](key)
      data.fetch(key)
    end

    def fetch(key)
      data.fetch(key)
    end

    def backend_root
      File.join(fetch("deploy").fetch("app_root"), "backend")
    end

    def frontend_root
      File.join(fetch("deploy").fetch("app_root"), "frontend")
    end

    def repositories_root
      File.join(fetch("deploy").fetch("app_root"), "repositories")
    end

    def public?
      fetch("deployment_mode") == "public"
    end

    def lan?
      fetch("deployment_mode") == "lan"
    end

    def validate!
      mode = data["deployment_mode"]
      raise ValidationError, "deployment_mode must be lan or public" unless %w[lan public].include?(mode)
      validate_deploy!
      validate_app!("backend")
      validate_app!("frontend")
      validate_frontend!
      validate_https!
      true
    end

    private

    def load_file(path)
      return {} unless File.exist?(path)

      YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
    end

    def deep_merge(base, override)
      base.merge(override) do |_key, old_value, new_value|
        old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
      end
    end

    def validate_deploy!
      deploy = data.fetch("deploy")
      %w[user home app_root].each { |key| present!(deploy[key], "deploy.#{key}") }
      reject_traversal!(deploy["app_root"], "deploy.app_root")
    end

    def validate_app!(name)
      app = data.fetch(name)
      present!(app["repository"], "#{name}.repository")
      positive_integer!(app["keep_releases"], "#{name}.keep_releases")
    end

    def validate_frontend!
      frontend = data.fetch("frontend")
      command = frontend["build_command"]
      raise ValidationError, "frontend.build_command must not be empty" unless command.is_a?(Array) && !command.empty? && command.all? { |v| v.to_s != "" }
      output = frontend["output_directory"].to_s
      present!(output, "frontend.output_directory")
      raise ValidationError, "frontend.output_directory must be relative" if output.start_with?("/")
      reject_traversal!(output, "frontend.output_directory")
    end

    def validate_https!
      https = data.fetch("https")
      raise ValidationError, "https.challenge must be http-01" unless https["challenge"] == "http-01"
      return unless public?

      host = https["host"].to_s
      email = https["email"].to_s
      validate_public_host!(host)
      raise ValidationError, "https.email is required in public mode" unless email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
    end

    def validate_public_host!(host)
      present!(host, "https.host")
      raise ValidationError, "https.host must not include scheme" if host.include?("://")
      raise ValidationError, "https.host must not include path" if host.include?("/")
      raise ValidationError, "https.host must not be localhost" if host == "localhost"
      raise ValidationError, "https.host must be hostname, not IP" if ip_address?(host)
      raise ValidationError, "https.host is invalid" unless host.match?(/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z/i)
    end

    def present!(value, name)
      raise ValidationError, "#{name} is required" if value.nil? || value.to_s.empty?
    end

    def positive_integer!(value, name)
      raise ValidationError, "#{name} must be positive integer" unless value.to_i.positive?
    end

    def reject_traversal!(value, name)
      raise ValidationError, "#{name} must not include path traversal" if value.to_s.split(File::SEPARATOR).include?("..")
    end

    def ip_address?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
