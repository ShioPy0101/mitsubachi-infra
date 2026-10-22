# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module MitsubachiInfra
  module Deployment
    # release ごとに固定し、rollback でも元の commit・ビルド日時を再現する。
    module BuildMetadata
      def self.build_env(sha, at: Time.now.utc.iso8601)
        { 'VITE_GIT_COMMIT_SHA' => sha, 'VITE_BUILD_TIMESTAMP' => at }
      end

      def self.write(release:, component:, sha:, built_at: Time.now.utc.iso8601, output_directory: 'dist', dry_run: false)
        return if dry_run

        path = path_for(release, component, output_directory)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(component: component, environment: 'production', commit: sha,
                                              built_at: built_at, deployed_at: nil) + "\n")
      end

      def self.mark_deployed(release:, component:, output_directory: 'dist', at: Time.now.utc.iso8601, dry_run: false)
        return if dry_run

        path = path_for(release, component, output_directory)
        return unless File.file?(path)

        info = JSON.parse(File.read(path))
        info['deployed_at'] = at
        File.write(path, JSON.pretty_generate(info) + "\n")
      end

      def self.path_for(release, component, output_directory)
        component == 'frontend' ? File.join(release, output_directory, 'release-info.json') : File.join(release, 'build-info.json')
      end
      private_class_method :path_for
    end
  end
end
