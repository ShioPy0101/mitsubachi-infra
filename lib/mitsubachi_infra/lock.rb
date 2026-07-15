# frozen_string_literal: true

require "fileutils"
require_relative "errors"

module MitsubachiInfra
  class Lock
    PATH = "/var/lock/mitsubachi-infra.lock"

    def self.with(path = PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
        raise Error, "another mitsubachi-infra operation is running" unless file.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      ensure
        file&.flock(File::LOCK_UN)
      end
    end
  end
end
