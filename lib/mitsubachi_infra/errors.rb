# frozen_string_literal: true

module MitsubachiInfra
  class Error < StandardError; end
  class ValidationError < Error; end

  class CommandError < Error
    attr_reader :command, :status, :stdout, :stderr, :chdir, :user, :timeout

    def initialize(command:, status:, stdout:, stderr:, chdir: nil, user: nil, timeout: nil)
      @command = command
      @status = status
      @stdout = stdout
      @stderr = stderr
      @chdir = chdir
      @user = user
      @timeout = timeout
      super(build_message)
    end

    private

    def build_message
      parts = ["command failed status=#{status}", "command=#{command.join(' ')}"]
      parts << "chdir=#{chdir}" if chdir
      parts << "user=#{user}" if user
      parts << "timeout=#{timeout}" if timeout
      parts << "stdout=#{stdout}" unless stdout.to_s.empty?
      parts << "stderr=#{stderr}" unless stderr.to_s.empty?
      parts.join("\n")
    end
  end
end
