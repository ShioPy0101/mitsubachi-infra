# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'uri'
require_relative '../errors'

module MitsubachiInfra
  module Deployment
    class DatabaseBackup
      def initialize(config:, runner:, rails_command:, logger: $stderr)
        @config = config
        @runner = runner
        @rails_command = rails_command
        @logger = logger
      end

      def create!(directory)
        dump = File.join(directory, 'database.dump')
        checksum = "#{dump}.sha256"
        return dry_run_result(dump, checksum) if @runner.dry_run

        FileUtils.mkdir_p(directory)
        database_url = @rails_command.env_file_values.fetch('DATABASE_URL') do
          raise Error, 'DATABASE_URL is required for release backup'
        end
        @runner.run('pg_dump', '--format=custom', '--file', dump, '--dbname', database_url, timeout: 1800)
        raise Error, "database backup is empty: #{dump}" unless File.file?(dump) && File.size?(dump)
        File.chmod(0o640, dump)

        digest = Digest::SHA256.file(dump).hexdigest
        File.write(checksum, "#{digest}  database.dump\n", mode: 'w', perm: 0o640)
        verified = @runner.run('pg_restore', '--list', dump, allow_failure: true, timeout: 300).success?
        raise Error, "pg_restore could not read database backup: #{dump}" unless verified

        { path: dump, sha256: digest, checksum_path: checksum, verified: true }
      end

      private

      def dry_run_result(dump, checksum)
        @logger.puts("[DRY-RUN] pg_dump release backup -> #{dump}")
        { path: dump, sha256: nil, checksum_path: checksum, verified: false, dry_run: true }
      end
    end
  end
end
