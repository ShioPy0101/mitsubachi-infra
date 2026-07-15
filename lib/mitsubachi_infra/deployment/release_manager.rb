# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"

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
        File.join(root, "releases")
      end

      def current_link
        File.join(root, "current")
      end

      def shared_dir
        File.join(root, "shared")
      end

      def ensure_dirs(owner:)
        @runner.run("install", "-d", "-o", owner, "-g", owner, "-m", "0755", root, releases_dir, shared_dir)
      end

      def release_id(commit_sha)
        "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{commit_sha[0, 12]}-#{$$}-#{SecureRandom.hex(3)}"
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
        Dir.glob(File.join(releases_dir, "*")).select { |path| File.directory?(path) }.sort_by { |path| File.mtime(path) }
      end

      def activate(path)
        parent = File.dirname(current_link)
        tmp = File.join(parent, ".current.tmp.#{$$}")
        FileUtils.ln_sf(path, tmp)
        FileUtils.mv(tmp, current_link, force: true)
      end

      def cleanup(protected_paths: [])
        protected = ([current_release] + protected_paths).compact.map { |path| File.realpath(path) rescue path }
        candidates = release_paths
        remove = candidates[0, [candidates.length - @keep, 0].max]
        remove.each do |path|
          real = File.realpath(path) rescue path
          next if protected.include?(real)

          FileUtils.rm_rf(path) unless @runner.dry_run
        end
      end
    end
  end
end
