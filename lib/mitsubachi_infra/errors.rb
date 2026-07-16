# frozen_string_literal: true

module MitsubachiInfra
  class Error < StandardError; end
  class ValidationError < Error; end

  class CommandError < Error
    attr_reader :command, :status, :stdout, :stderr

    def initialize(command:, status:, stdout:, stderr:)
      @command = command
      @status = status
      @stdout = stdout
      @stderr = stderr
      super("command failed status=#{status}: #{command.join(' ')}")
    end
  end
end
