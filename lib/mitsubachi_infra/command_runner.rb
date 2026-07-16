# frozen_string_literal: true

require 'open3'
require 'timeout'
require_relative 'errors'

module MitsubachiInfra
  class CommandRunner
    SECRET_PATTERNS = [
      /(DATABASE(?:_CACHE|_QUEUE|_CABLE)?_URL=)[^\s]+/,
      /(RAILS_MASTER_KEY=)[^\s]+/,
      /(SECRET_KEY_BASE=)[^\s]+/,
      /(RESEND_API_KEY=)[^\s]+/,
      /(SMTP_PASSWORD=)[^\s]+/,
      /([A-Z0-9_]*(?:PASSWORD|TOKEN|SECRET)=)[^\s]+/,
      /(-----BEGIN [A-Z ]*PRIVATE KEY-----).*?(-----END [A-Z ]*PRIVATE KEY-----)/m,
      %r{(postgres(?:ql)?://[^:/@\s]+:)[^@\s]+(@)}
    ].freeze

    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success?
        status.zero?
      end
    end

    attr_accessor :dry_run

    def initialize(logger:, dry_run: false)
      @logger = logger
      @dry_run = dry_run
    end

    def run(*command, env: {}, chdir: nil, timeout: 600, user: nil, deploy_env: nil, allow_failure: false)
      flattened = command.flatten
      raise Error, 'command argv must not contain nil' if flattened.any?(&:nil?)

      argv = flattened.map(&:to_s)
      display_user = user
      argv = user_command(user, deploy_env, argv) if present?(user)
      log_command(argv, chdir, user: display_user)
      return Result.new(stdout: '', stderr: '', status: 0) if dry_run

      stdout = +''
      stderr = +''
      status = nil

      Timeout.timeout(timeout) do
        options = {}
        options[:chdir] = chdir if chdir && !chdir.empty?

        stdout, stderr, wait = Open3.capture3(
          env.transform_values(&:to_s),
          *argv,
          **options
        )

        status = wait.exitstatus
      end
      result = Result.new(stdout: stdout, stderr: stderr, status: status)
      log_output(stdout, stderr) if result.success?
      if !result.success? && !allow_failure
        raise CommandError.new(command: argv, status: status, stdout: mask(stdout),
                               stderr: mask(stderr), chdir: chdir, user: display_user, timeout: timeout)
      end

      result
    rescue Timeout::Error
      raise Error, "command timed out after #{timeout}s: #{mask(argv.join(' '))}"
    rescue Errno::ENOENT => e
      return Result.new(stdout: '', stderr: e.message, status: 127) if allow_failure

      raise Error, "command not found: #{mask(argv.join(' '))}\nstderr=#{mask(e.message)}"
    end

    def deploy(*command, config:, chdir: nil, timeout: 600, allow_failure: false, env: {})
      deploy = config.fetch('deploy')
      home = deploy.fetch('home')
      deploy_path = [
        "#{home}/.rbenv/bin",
        "#{home}/.rbenv/shims",
        '/usr/local/bin',
        '/usr/bin',
        '/bin'
      ].join(':')
      deploy_environment = {
        'HOME' => home,
        'USER' => deploy.fetch('user'),
        'LOGNAME' => deploy.fetch('user'),
        'RBENV_ROOT' => "#{home}/.rbenv",
        'PATH' => deploy_path
      }.merge(env)
      run(*command,
          chdir: chdir || home,
          timeout: timeout,
          user: deploy.fetch('user'),
          deploy_env: deploy_environment,
          allow_failure: allow_failure)
    end

    def mask(text)
      SECRET_PATTERNS.reduce(text.to_s) { |acc, pattern| acc.gsub(pattern, '\\1<redacted>\\2') }
    end

    private

    def present?(value)
      !value.nil? && value.to_s != ''
    end

    def user_command(user, deploy_env, argv)
      env_args = deploy_env.to_a.flat_map { |key, value| ["#{key}=#{value}"] }
      ['sudo', '-u', user, '-H', 'env', *env_args, *argv]
    end

    def log_command(argv, chdir, user:)
      prefix = dry_run ? '[DRY-RUN]' : '[RUN]'
      dir = chdir ? " cwd=#{chdir}" : ''
      run_user = user ? " user=#{user}" : ''
      @logger.puts("#{prefix}#{dir}#{run_user} #{mask(argv.join(' '))}")
    end

    def log_output(stdout, stderr)
      @logger.puts("[STDOUT] #{mask(stdout).strip}") unless stdout.to_s.strip.empty?
      @logger.puts("[STDERR] #{mask(stderr).strip}") unless stderr.to_s.strip.empty?
    end
  end
end
