# frozen_string_literal: true

require "open3"
require "timeout"
require_relative "errors"

module MitsubachiInfra
  class CommandRunner
    SECRET_PATTERNS = [
      /(DATABASE(?:_CACHE|_QUEUE|_CABLE)?_URL=)[^\s]+/,
      /(RAILS_MASTER_KEY=)[^\s]+/,
      /(SECRET_KEY_BASE=)[^\s]+/,
      /(RESEND_API_KEY=)[^\s]+/,
      %r{(postgres(?:ql)?://[^:/@\s]+:)[^@\s]+(@)}
    ].freeze

    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success?
        status.zero?
      end
    end

    attr_reader :dry_run

    def initialize(logger:, dry_run: false)
      @logger = logger
      @dry_run = dry_run
    end

    def run(*command, env: {}, chdir: nil, timeout: 600, user: nil, deploy_env: nil, allow_failure: false)
      argv = command.flatten.compact.map(&:to_s)
      argv = user_command(user, deploy_env, argv) if user
      log_command(argv, chdir)
      return Result.new(stdout: "", stderr: "", status: 0) if dry_run

      stdout = +""
      stderr = +""
      status = nil
      Timeout.timeout(timeout) do
        stdout, stderr, wait = Open3.capture3(env.transform_values(&:to_s), *argv, chdir: chdir)
        status = wait.exitstatus
      end
      result = Result.new(stdout: stdout, stderr: stderr, status: status)
      raise CommandError.new(command: argv, status: status, stdout: mask(stdout), stderr: mask(stderr)) if !result.success? && !allow_failure

      result
    rescue Timeout::Error
      raise Error, "command timed out: #{mask(argv.join(" "))}"
    end

    def deploy(*command, config:, chdir: nil, timeout: 600, allow_failure: false, env: {})
      deploy = config.fetch("deploy")
      home = deploy.fetch("home")
      deploy_path = [
        "#{home}/.rbenv/bin",
        "#{home}/.rbenv/shims",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
      ].join(":")
      deploy_environment = {
        "HOME" => home,
        "USER" => deploy.fetch("user"),
        "LOGNAME" => deploy.fetch("user"),
        "RBENV_ROOT" => "#{home}/.rbenv",
        "PATH" => deploy_path
      }.merge(env)
      run(*command,
          chdir: chdir || home,
          timeout: timeout,
          user: deploy.fetch("user"),
          deploy_env: deploy_environment,
          allow_failure: allow_failure)
    end

    def mask(text)
      SECRET_PATTERNS.reduce(text.to_s) { |acc, pattern| acc.gsub(pattern, "\\1<redacted>\\2") }
    end

    private

    def user_command(user, deploy_env, argv)
      env_args = deploy_env.to_a.flat_map { |key, value| ["#{key}=#{value}"] }
      ["sudo", "-u", user, "-H", "env", *env_args, *argv]
    end

    def log_command(argv, chdir)
      prefix = dry_run ? "[DRY-RUN]" : "[RUN]"
      dir = chdir ? " cwd=#{chdir}" : ""
      @logger.puts("#{prefix}#{dir} #{mask(argv.join(" "))}")
    end
  end
end
