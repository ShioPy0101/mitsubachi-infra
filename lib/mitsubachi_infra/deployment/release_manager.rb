# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'securerandom'
require 'time'
require_relative '../errors'

module MitsubachiInfra
  module Deployment
    class ReleaseManager
      attr_reader :root

      def initialize(root:, runner:, keep:)
        @root = root
        @runner = runner
        @keep = keep.to_i
      end

      def releases_dir
        File.join(root, 'releases')
      end

      def current_link
        File.join(root, 'current')
      end

      def shared_dir
        File.join(root, 'shared')
      end

      def ensure_dirs(owner:)
        @runner.run('install', '-d', '-o', owner, '-g', owner, '-m', '0755', root, releases_dir, shared_dir)
      end

      def release_id(commit_sha)
        "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{commit_sha[0, 12]}-#{$PROCESS_ID}-#{SecureRandom.hex(3)}"
      end

      def current_release
        return nil unless File.symlink?(current_link)

        File.realpath(current_link)
      rescue Errno::ENOENT
        nil
      end

      def previous_release
        current = current_release
        releases = release_paths.reject { |path| path == current }
        releases[-1]
      end

      def release_paths
        Dir.glob(File.join(releases_dir, '*')).select do |path|
          File.directory?(path)
        end.sort_by { |path| File.mtime(path) }
      end

      def activate(path)
        parent = File.dirname(current_link)
        tmp = File.join(parent, ".current.tmp.#{$PROCESS_ID}")
        assert_replaceable_current!
        FileUtils.rm_f(tmp)
        File.symlink(path, tmp)
        File.rename(tmp, current_link)
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      def cleanup(protected_paths: [])
        protected = ([current_release] + protected_paths).compact.map do |path|
          File.realpath(path)
        rescue StandardError
          path
        end
        candidates = release_paths
        remove = candidates[0, [candidates.length - @keep, 0].max]
        remove.each do |path|
          real = begin
            File.realpath(path)
          rescue StandardError
            path
          end
          next if protected.include?(real)

          FileUtils.rm_rf(path) unless @runner.dry_run
        end
      end

      def assert_replaceable_current!
        return unless File.exist?(current_link) || File.symlink?(current_link)
        return if File.symlink?(current_link)

        raise Error, "current path exists and is not a symlink: #{current_link}"
      end
    end
  end
end
