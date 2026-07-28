# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module MitsubachiInfra
  module Deployment
    class ReleaseReport
      attr_reader :directory, :data

      def initialize(release_id:, root:, backend_ref:, frontend_ref:, dry_run: false)
        @directory = File.join(root, release_id)
        @dry_run = dry_run
        @data = {
          release_id: release_id, status: 'running', failed_step: nil,
          started_at: Time.now.iso8601, completed_at: nil,
          requested_backend_ref: backend_ref, requested_frontend_ref: frontend_ref,
          backend_revision: nil, frontend_revision: nil,
          previous_backend_release_id: nil, previous_frontend_release_id: nil,
          completed_steps: [], steps: [], database_backup: {}, migration: {},
          health_check: {}, smoke_test: {}, maintenance: {}
        }
        FileUtils.mkdir_p(directory) unless dry_run
        save
      end

      def path(name)
        File.join(directory, name)
      end

      def record(result)
        data[:steps] << result.to_h
        data[:completed_steps] << result.name if result.succeeded
        save
      end

      def merge(key, values)
        data[key] = data.fetch(key, {}).merge(values)
        save
      end

      def assign(values)
        data.merge!(values)
        save
      end

      def finish(status:, failed_step: nil, error: nil, exit_code: nil)
        data[:status] = status
        data[:failed_step] = failed_step
        data[:error] = error
        data[:exit_code] = exit_code
        data[:completed_at] = Time.now.iso8601
        save
      end

      def save
        return if @dry_run

        FileUtils.mkdir_p(directory)
        temp = "#{path('release.json')}.tmp.#{$PROCESS_ID}"
        File.write(temp, JSON.pretty_generate(data) + "\n", mode: 'w', perm: 0o640)
        File.rename(temp, path('release.json'))
      ensure
        FileUtils.rm_f(temp) if defined?(temp) && temp
      end
    end
  end
end
