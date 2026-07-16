# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'shellwords'
require 'tempfile'
require_relative 'command_runner'
require_relative 'errors'

module MitsubachiInfra
  class PostgreSQLWalArchive
    Cluster = Struct.new(:version, :name, :port, :status, :owner, :data_directory, :log_file, keyword_init: true)

    ARCHIVE_COMMAND_FORMAT = '%<script>s %%p %%f'

    attr_reader :config_path

    def initialize(config:, runner:, logger: $stderr)
      @config = config
      @runner = runner
      @logger = logger
      @wal_config = config.fetch('postgresql').fetch('wal_archive')
      @config_path = nil
    end

    def configure(verify: false)
      cluster = detect_cluster
      settings = current_settings(cluster)
      validate_mount!
      prepare_archive_directory!
      script_changed = install_archive_script!
      config_changed = install_postgresql_config!(cluster)
      restart = restart_required?(settings, script_changed: script_changed, config_changed: config_changed)

      if restart
        @logger.puts("[RUN] pg_ctlcluster #{cluster.version} #{cluster.name} restart")
        begin
          @runner.run('pg_ctlcluster', cluster.version, cluster.name, 'restart')
        rescue StandardError
          restore_file_snapshot(@config_path, @last_config_snapshot)
          @runner.run('pg_ctlcluster', cluster.version, cluster.name, 'restart', allow_failure: true)
          raise
        end
      else
        @logger.puts('[SKIP] PostgreSQL restart is not required')
      end

      unless @runner.dry_run
        verify_runtime!(cluster)
        verify_archive!(cluster) if verify
      end
      @logger.puts('[OK] PostgreSQL WAL archive is configured')
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "failed to configure PostgreSQL WAL archive: #{e.message}"
    end

    def verify
      cluster = detect_cluster
      verify_runtime!(cluster)
      verify_archive!(cluster)
      @logger.puts('[OK] PostgreSQL WAL archive verification succeeded')
    end

    def status(json: false)
      cluster = detect_cluster
      settings = current_settings(cluster)
      archiver = archiver_stats(cluster)
      rows = {
        cluster: "#{cluster.version}/#{cluster.name}",
        mount_point: mount_point,
        mount_mounted: mounted?,
        archive_directory: archive_directory,
        archive_directory_usage: command_stdout('du', '-sh', archive_directory, allow_failure: true).split.first,
        external_hdd_free: command_stdout('df', '-h', mount_point, allow_failure: true).lines.last.to_s.strip,
        pg_wal_usage: pg_wal_usage(settings.fetch('data_directory')),
        archive_mode: settings.fetch('archive_mode'),
        archive_command: settings.fetch('archive_command'),
        archive_library: settings.fetch('archive_library'),
        archived_count: archiver['archived_count'],
        failed_count: archiver['failed_count'],
        last_archived_wal: archiver['last_archived_wal'],
        last_archived_time: archiver['last_archived_time'],
        last_failed_wal: archiver['last_failed_wal'],
        last_failed_time: archiver['last_failed_time']
      }
      if json
        puts JSON.pretty_generate(rows)
      else
        rows.each { |key, value| puts "#{key}: #{value}" }
        warnings(rows).each { |warning| puts "warning: #{warning}" }
      end
    end

    def detect_cluster
      result = @runner.run('pg_lsclusters', '--no-header')
      clusters = parse_clusters(result.stdout)
      version = @wal_config['version'].to_s
      name = @wal_config['cluster'].to_s
      clusters = clusters.select { |cluster| cluster.version == version } unless version.empty?
      clusters = clusters.select { |cluster| cluster.name == name } unless name.empty?
      online = clusters.select { |cluster| cluster.status == 'online' }
      return online.first if online.length == 1

      raise ValidationError, 'no running PostgreSQL cluster found' if online.empty?

      candidates = online.map { |cluster| "#{cluster.version}/#{cluster.name}" }.join(', ')
      raise ValidationError, "multiple running PostgreSQL clusters found: #{candidates}. Set postgresql.wal_archive.version and cluster."
    end

    def parse_clusters(output)
      output.lines.filter_map do |line|
        parts = line.split(/\s+/, 7)
        next if parts.length < 6

        Cluster.new(version: parts[0], name: parts[1], port: parts[2], status: parts[3], owner: parts[4],
                    data_directory: parts[5], log_file: parts[6].to_s.strip)
      end
    end

    def archive_command
      format(ARCHIVE_COMMAND_FORMAT, script: archive_script.shellescape)
    end

    def archive_script_content
      <<~BASH
        #!/usr/bin/env bash
        set -euo pipefail

        mount_point=#{mount_point.shellescape}
        archive_dir=#{archive_directory.shellescape}
        source_path="${1:-}"
        wal_name="${2:-}"
        temporary=""

        fail() {
          printf '%s\\n' "mitsubachi wal archive failed: $*" >&2
          logger -t mitsubachi-wal-archive -- "archive failed: $*" || true
          exit 1
        }

        cleanup() {
          if [[ -n "$temporary" ]]; then
            rm -f -- "$temporary"
          fi
        }
        trap cleanup EXIT

        [[ -n "$source_path" ]] || fail "missing source path"
        [[ -n "$wal_name" ]] || fail "missing WAL filename"
        [[ "$wal_name" != */* ]] || fail "invalid WAL filename"
        [[ "$wal_name" != *..* ]] || fail "invalid WAL filename"
        [[ "$wal_name" != *$'\\n'* && "$wal_name" != *$'\\r'* && "$wal_name" != *$'\\0'* ]] || fail "invalid WAL filename"
        [[ "$wal_name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid WAL filename"
        [[ -f "$source_path" ]] || fail "source WAL does not exist"
        mountpoint -q "$mount_point" || fail "$mount_point is not mounted"
        [[ -d "$archive_dir" ]] || fail "$archive_dir does not exist"
        [[ ! -L "$archive_dir" ]] || fail "$archive_dir must not be a symlink"
        [[ -w "$archive_dir" ]] || fail "$archive_dir is not writable"

        destination="$archive_dir/$wal_name"
        if [[ -e "$destination" ]]; then
          [[ -f "$destination" && ! -L "$destination" ]] || fail "destination exists but is not a regular file"
          if cmp --silent -- "$source_path" "$destination"; then
            exit 0
          fi
          fail "destination already exists with different content: $wal_name"
        fi

        temporary="$archive_dir/.${wal_name}.tmp.$$"
        cp --preserve=mode,timestamps -- "$source_path" "$temporary"
        sync -f "$temporary"
        mv -T -- "$temporary" "$destination"
        temporary=""
        sync -f "$destination"
        sync -f "$archive_dir"
        cmp --silent -- "$source_path" "$destination" || fail "copied WAL differs from source"
      BASH
    end

    private

    def current_settings(cluster)
      {
        'data_directory' => show_setting(cluster, 'data_directory'),
        'config_file' => show_setting(cluster, 'config_file'),
        'hba_file' => show_setting(cluster, 'hba_file'),
        'archive_mode' => show_setting(cluster, 'archive_mode'),
        'archive_command' => show_setting(cluster, 'archive_command'),
        'archive_library' => show_setting(cluster, 'archive_library', allow_missing: true)
      }
    end

    def psql(cluster, sql)
      @runner.run('sudo', '-u', 'postgres', 'psql', '-p', cluster.port, '-At', '-v', 'ON_ERROR_STOP=1', '-c', sql).stdout
    end

    def show_setting(cluster, name, allow_missing: false)
      result = @runner.run('sudo', '-u', 'postgres', 'psql', '-p', cluster.port, '-At', '-v', 'ON_ERROR_STOP=1', '-c',
                           "SHOW #{name};", allow_failure: allow_missing)
      return '' if allow_missing && !result.success?

      result.stdout.strip
    end

    def archiver_stats(cluster)
      output = psql(cluster, <<~SQL)
        SELECT archived_count, failed_count, COALESCE(last_archived_wal, ''), COALESCE(last_archived_time::text, ''), COALESCE(last_failed_wal, ''), COALESCE(last_failed_time::text, '')
        FROM pg_stat_archiver;
      SQL
      values = output.strip.split('|', -1)
      keys = %w[archived_count failed_count last_archived_wal last_archived_time last_failed_wal last_failed_time]
      Hash[keys.zip(values)]
    end

    def validate_mount!
      @runner.run('findmnt', '--mountpoint', mount_point)
      raise ValidationError, "#{mount_point} is not a directory" if !@runner.dry_run && !File.directory?(mount_point)
    end

    def mounted?
      @runner.run('findmnt', '--mountpoint', mount_point, allow_failure: true).success?
    end

    def prepare_archive_directory!
      if !@runner.dry_run && File.exist?(archive_directory) && !File.directory?(archive_directory)
        raise ValidationError, "archive directory path exists but is not a directory: #{archive_directory}"
      end
      if !@runner.dry_run && File.symlink?(archive_directory)
        raise ValidationError, "archive directory must not be a symlink: #{archive_directory}"
      end
      @runner.run('install', '-d', '-o', 'postgres', '-g', 'postgres', '-m', '0700', archive_directory)
      @runner.run('sudo', '-u', 'postgres', 'test', '-w', archive_directory)
    end

    def install_archive_script!
      install_file_if_changed(archive_script, archive_script_content, owner: 'root', group: 'root', mode: '0755',
                              validate: ['bash', '-n'])
    end

    def install_postgresql_config!(cluster)
      settings = current_settings(cluster)
      config_file = settings.fetch('config_file')
      conf_dir = File.dirname(config_file)
      confd = File.join(conf_dir, 'conf.d')
      raise ValidationError, "PostgreSQL conf.d directory is missing: #{confd}" unless @runner.dry_run || File.directory?(confd)

      assert_conf_d_included!(config_file)
      @config_path = File.join(confd, @wal_config.fetch('config_filename'))
      detect_archive_conflicts!(settings, confd, @config_path)
      content = postgresql_config_content
      previous = file_snapshot(@config_path)
      @last_config_snapshot = previous
      changed = install_file_if_changed(@config_path, content, owner: 'root', group: 'postgres', mode: '0640')
      validate_postgresql_config!(cluster)
      changed
    rescue StandardError
      restore_file_snapshot(@config_path, previous) if previous
      raise
    end

    def postgresql_config_content
      lines = [
        "# Managed by mitsubachi-infra. Do not edit by hand.\n",
        "archive_mode = on\n",
        "archive_command = '#{archive_command.gsub("'", "''")}'\n"
      ]
      timeout = @wal_config['archive_timeout'].to_s
      lines << "archive_timeout = #{timeout}\n" unless timeout.empty?
      lines.join
    end

    def assert_conf_d_included!(config_file)
      return if @runner.dry_run

      content = File.read(config_file)
      return if content.match?(/^\s*include_dir\s*=\s*'?conf\.d'?/i)

      raise ValidationError, "#{config_file} does not include conf.d; refusing to hide WAL archive settings"
    end

    def detect_archive_conflicts!(settings, confd, target)
      return if @runner.dry_run

      paths = [
        settings.fetch('config_file'),
        File.join(settings.fetch('data_directory'), 'postgresql.auto.conf')
      ] + Dir.glob(File.join(confd, '*.conf'))
      conflicts = paths.reject { |path| File.expand_path(path) == File.expand_path(target) }.select do |path|
        File.file?(path) && File.readlines(path).any? { |line| line.match?(/^\s*archive_(mode|command|library)\s*=/i) }
      end
      return if conflicts.empty?

      raise ValidationError, "conflicting PostgreSQL archive settings found: #{conflicts.join(', ')}"
    end

    def install_file_if_changed(path, content, owner:, group:, mode:, validate: nil)
      if @runner.dry_run
        @logger.puts("[DRY-RUN] write #{path}")
        return true
      end
      if File.file?(path) && File.read(path) == content
        @logger.puts("[OK] #{path} is unchanged")
        @runner.run('chown', "#{owner}:#{group}", path)
        @runner.run('chmod', mode, path)
        return false
      end

      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      Tempfile.create([".#{File.basename(path)}", '.tmp'], dir) do |tmp|
        tmp.write(content)
        tmp.flush
        tmp.fsync
        File.chmod(mode.to_i(8), tmp.path)
        @runner.run(*validate, tmp.path) if validate
        File.rename(tmp.path, path)
      end
      @runner.run('chown', "#{owner}:#{group}", path)
      @runner.run('chmod', mode, path)
      true
    end

    def file_snapshot(path)
      return { exists: false } unless path && (File.exist?(path) || File.symlink?(path))

      raise ValidationError, "refusing to manage symlink config file: #{path}" if File.symlink?(path)

      { exists: true, content: File.binread(path), mode: File.stat(path).mode & 0o777 }
    end

    def restore_file_snapshot(path, snapshot)
      return unless path && snapshot

      if snapshot[:exists]
        File.binwrite(path, snapshot.fetch(:content))
        File.chmod(snapshot.fetch(:mode), path)
      else
        FileUtils.rm_f(path)
      end
    end

    def validate_postgresql_config!(cluster)
      @runner.run('sudo', '-u', 'postgres', 'postgres', '-D', current_settings(cluster).fetch('data_directory'), '-C',
                  'archive_mode')
    end

    def restart_required?(settings, script_changed:, config_changed:)
      _ = script_changed
      config_changed ||
        settings.fetch('archive_mode') != 'on' ||
        settings.fetch('archive_command') != archive_command
    end

    def verify_runtime!(cluster)
      settings = current_settings(cluster)
      raise Error, "archive_mode is #{settings.fetch('archive_mode')}, expected on" unless settings.fetch('archive_mode') == 'on'
      unless settings.fetch('archive_command') == archive_command
        raise Error, "archive_command is #{settings.fetch('archive_command')}, expected #{archive_command}"
      end
      library = settings.fetch('archive_library')
      raise Error, "archive_library is #{library}, expected empty" unless library.empty?
    end

    def verify_archive!(cluster)
      before = archiver_stats(cluster)
      psql(cluster, 'SELECT pg_switch_wal();')
      30.times do
        sleep 1 unless @runner.dry_run
        current = archiver_stats(cluster)
        return if current['archived_count'].to_i > before['archived_count'].to_i
        raise Error, "WAL archive failed: #{current.inspect}" if current['failed_count'].to_i > before['failed_count'].to_i
      end

      raise Error, "WAL archive did not complete within 30 seconds: #{archiver_stats(cluster).inspect}"
    end

    def pg_wal_usage(data_directory)
      command_stdout('du', '-sh', File.join(data_directory, 'pg_wal'), allow_failure: true).split.first
    end

    def command_stdout(*command, allow_failure: false)
      @runner.run(*command, allow_failure: allow_failure).stdout.to_s
    end

    def warnings(rows)
      warnings = []
      warnings << "#{mount_point} is not mounted" unless rows[:mount_mounted]
      warnings << 'WAL archive has recent failures' if rows[:last_failed_time].to_s > rows[:last_archived_time].to_s
      warnings
    end

    def mount_point
      @wal_config.fetch('mount_point')
    end

    def archive_directory
      @wal_config.fetch('archive_directory')
    end

    def archive_script
      @wal_config.fetch('archive_script')
    end
  end
end
