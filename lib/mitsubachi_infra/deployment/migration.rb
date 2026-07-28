# frozen_string_literal: true

require 'json'
require_relative '../errors'

module MitsubachiInfra
  module Deployment
    class Migration
      ZERO_KEYS = %w[users_without_membership duplicate_memberships organization_mismatches
                     unmigrated_count duplicate_count mismatch_count].freeze

      def initialize(rails_command:, runner:)
        @rails_command = rails_command
        @runner = runner
      end

      def snapshot!(release:, output:)
        task!('deployment:pre_migration_snapshot', release: release, output: output)
        parse_json!(output)
      end

      def migrate!(release:)
        @rails_command.rails('db:migrate', release: release, timeout: 1800)
        true
      end

      def verify!(release:, output:)
        task!('deployment:verify_migration', release: release, output: output)
        report = parse_json!(output)
        raise Error, 'migration verification reported valid=false' unless report['valid'] == true

        count_keys = report.keys.select { |key| key.match?(/without|unmigrated|duplicate|mismatch|invalid|orphan/i) }
        failures = (ZERO_KEYS + count_keys).uniq.select { |key| report.key?(key) && report[key].to_i != 0 }
        raise Error, "migration verification has non-zero counters: #{failures.join(', ')}" unless failures.empty?

        report
      end

      def prepare_smoke_credentials!(release:, output:, task:)
        task!(task, release: release, output: output)
        report = parse_json!(output, mode: 0o600)
        raise Error, 'smoke credential task generated no users' unless report['users'].is_a?(Hash) && report['users'].any?

        report
      end

      private

      def task!(name, release:, output:)
        @rails_command.rails(name, release: release, timeout: 1800, env: { 'OUTPUT' => output })
      end

      def parse_json!(path, mode: 0o640)
        return {} if @runner.dry_run
        raise Error, "deployment task did not create JSON: #{path}" unless File.file?(path)

        parsed = JSON.parse(File.read(path))
        File.chmod(mode, path)
        parsed
      rescue JSON::ParserError => e
        raise Error, "deployment task generated invalid JSON: #{path}: #{e.message}"
      end
    end
  end
end
