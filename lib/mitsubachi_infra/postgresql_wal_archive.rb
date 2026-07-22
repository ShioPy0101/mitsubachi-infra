# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'shellwords'
require 'tempfile'
require 'time'
require_relative 'command_runner'
require_relative 'errors'

module MitsubachiInfra
  class PostgreSQLWalArchive
    Cluster = Struct.new(:version, :name, :port, :status, :owner, :data_directory, :log_file, keyword_init: true)

    ARCHIVE_COMMAND_FORMAT = '%<script>s %%p %%f'
    EXPECTED_WAL_LEVEL = 'replica'
    EXPECTED_ARCHIVE_MODE = 'on'
    DEFAULT_TEST_TIMEOUT = 60

    attr_reader :config_path

    def initialize(config:, runner:, logger: $stderr, root_directory: nil)
      @config = config
      @runner = runner
      @logger = logger
      @wal_config = config.fetch('postgresql').fetch('wal_archive').dup
      apply_root_directory!(root_directory) if root_directory
      @config_path = nil
    end

    def configure(verify: false)
      enable(verify: verify)
    end

    def enable(verify: false, yes: false)
      _ = yes
      cluster = detect_cluster
      settings = current_settings(cluster)
      validate_mount!
      prepare_directories!
      script_changed = install_archive_script!
      backup_auto_conf!(settings)
      config_changed = install_postgresql_config!(cluster, settings)
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
        test(timeout: DEFAULT_TEST_TIMEOUT) if verify
      end
      @logger.puts('[WARN] Backup destination is not a disk-failure backup if it shares the same physical disk as PostgreSQL data_directory.')
      @logger.puts('[OK] PostgreSQL WAL archive is configured')
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "failed to configure PostgreSQL WAL archive: #{e.message}"
    end

    def disable(yes: false)
      _ = yes
      cluster = detect_cluster
      settings = current_settings(cluster)
      backup_auto_conf!(settings)
      run_alter_system(cluster, 'archive_mode', 'off')
      validate_postgresql_config!(cluster)
      @logger.puts("[RUN] pg_ctlcluster #{cluster.version} #{cluster.name} restart")
      @runner.run('pg_ctlcluster', cluster.version, cluster.name, 'restart')
      return if @runner.dry_run

      after = current_settings(cluster)
      raise Error, "archive_mode is #{after.fetch('archive_mode')}, expected off" unless after.fetch('archive_mode') == 'off'

      @logger.puts('[OK] PostgreSQL WAL archive is disabled. Existing WAL archives and base backups were not deleted.')
    rescue StandardError => e
      raise Error, "failed to disable PostgreSQL WAL archive: #{e.message}"
    end

    def verify
      test
      @logger.puts('[OK] PostgreSQL WAL archive verification succeeded')
    end

    def status(json: false)
      cluster = detect_cluster
      settings = current_settings(cluster)
      archiver = archiver_stats(cluster)
      archive_stats = directory_stats(archive_directory)
      mount_stats = mount_status
      free = free_capacity(mount_point)
      state = status_state(settings, archiver, mount_stats, free)
      rows = {
        status: state,
        cluster: "#{cluster.version}/#{cluster.name}",
        mount_point: mount_point,
        mount_mounted: mount_stats[:mounted],
        archive_directory: archive_directory,
        archive_directory_owner: path_owner(archive_directory),
        archive_directory_mode: path_mode(archive_directory),
        archive_file_count: archive_stats[:count],
        archive_total_bytes: archive_stats[:bytes],
        archive_last_modified: archive_stats[:last_modified],
        external_hdd_free: free[:line],
        external_hdd_free_percent: free[:available_percent],
        pg_wal_usage: pg_wal_usage(settings.fetch('data_directory')),
        wal_level: settings.fetch('wal_level'),
        archive_mode: settings.fetch('archive_mode'),
        archive_command: settings.fetch('archive_command'),
        archive_timeout: settings.fetch('archive_timeout'),
        archive_library: settings.fetch('archive_library'),
        archived_count: archiver['archived_count'],
        failed_count: archiver['failed_count'],
        last_archived_wal: archiver['last_archived_wal'],
        last_archived_time: archiver['last_archived_time'],
        last_failed_wal: archiver['last_failed_wal'],
        last_failed_time: archiver['last_failed_time'],
        stats_reset: archiver['stats_reset'],
        archive_command_expected: settings.fetch('archive_command') == archive_command,
        warning: 'Same physical disk for PostgreSQL data and backup destination is not a disk-failure backup.'
      }
      if json
        puts JSON.pretty_generate(rows)
      else
        rows.each { |key, value| puts "#{key}: #{value}" }
        warnings(rows).each { |warning| puts "warning: #{warning}" }
      end
    end

    def test(timeout: DEFAULT_TEST_TIMEOUT)
      cluster = detect_cluster
      settings = current_settings(cluster)
      verify_runtime!(cluster)
      validate_mount!
      @logger.puts('[WARN] This test switches the current PostgreSQL WAL segment with pg_switch_wal().')
      before = archiver_stats(cluster)
      before_wal = before['last_archived_wal'].to_s
      current_lsn = psql(cluster, 'SELECT pg_current_wal_lsn();').strip
      switched = psql(cluster, 'SELECT pg_switch_wal();').strip
      deadline = Time.now + timeout.to_i
      last = before
      until Time.now >= deadline
        sleep 1 unless @runner.dry_run
        last = archiver_stats(cluster)
        archived_wal = last['last_archived_wal'].to_s
        if archived_wal != '' && archived_wal != before_wal
          path = File.join(archive_directory, archived_wal)
          unless @runner.dry_run
            raise Error, "archived WAL file is missing: #{path}" unless File.file?(path)
            raise Error, "archived WAL file is empty: #{path}" unless File.size(path).positive?
          end
          @logger.puts("[OK] WAL archive test succeeded: #{archived_wal} current_lsn_before=#{current_lsn} switched_lsn=#{switched}")
          return
        end
        if last['failed_count'].to_i > before['failed_count'].to_i
          raise Error, "WAL archive failed during test: #{last.inspect}"
        end
      end
      raise Error, "WAL archive did not complete within #{timeout} seconds: #{last.inspect}"
    end

    def create_base_backup(checkpoint: 'fast', yes: false)
      _ = yes
      cluster = detect_cluster
      validate_mount!
      prepare_directories!
      timestamp = Time.now.strftime('%Y-%m-%dT%H%M%S%z')
      final_dir = File.join(base_backup_directory, timestamp)
      partial_dir = "#{final_dir}.partial"
      log_path = File.join(scripts_directory, "base-backup-#{timestamp}.log")
      raise ValidationError, "base backup already exists: #{final_dir}" if !@runner.dry_run && File.exist?(final_dir)

      started_at = Time.now.iso8601
      @runner.run('install', '-d', '-o', 'postgres', '-g', 'postgres', '-m', '0700', partial_dir)
      cmd = ['sudo', '-u', 'postgres', 'pg_basebackup',
             '--pgdata', partial_dir,
             '--format', 'plain',
             '--wal-method', 'stream',
             '--checkpoint', checkpoint,
             '--progress',
             '--verbose',
             '--manifest-checksums', 'SHA256',
             '-p', cluster.port]
      @logger.puts("[RUN] #{cmd.shelljoin}")
      begin
        result = @runner.run(*cmd)
        FileUtils.mkdir_p(scripts_directory) unless @runner.dry_run
        File.write(log_path, "#{result.stdout}#{result.stderr}") unless @runner.dry_run
        verify_base_backup!(partial_dir)
        metadata = {
          started_at: started_at,
          finished_at: Time.now.iso8601,
          cluster: "#{cluster.version}/#{cluster.name}",
          port: cluster.port,
          postgres_version: psql(cluster, 'SHOW server_version;').strip,
          checkpoint: checkpoint,
          wal_method: 'stream',
          manifest_checksums: 'SHA256',
          log_path: log_path
        }
        File.write(File.join(partial_dir, 'mitsubachi-backup.json'), JSON.pretty_generate(metadata)) unless @runner.dry_run
        @runner.run('mv', '-T', partial_dir, final_dir)
        @logger.puts("[OK] Base backup created: #{final_dir}")
      rescue StandardError => e
        @logger.puts("[ERROR] Base backup failed; partial directory kept at #{partial_dir}") unless @runner.dry_run
        raise Error, "failed to create base backup: #{e.message}"
      end
    end

    def list_base_backups(json: false)
      backups = base_backups
      if json
        puts JSON.pretty_generate(backups)
      else
        puts "base_backup_directory: #{base_backup_directory}"
        backups.each do |backup|
          puts "#{backup[:name]}\t#{backup[:bytes]} bytes\t#{backup[:created_at]}\t#{backup[:partial] ? 'PARTIAL' : 'OK'}"
        end
      end
    end

    def prune_base_backups(retention_days: nil, minimum: nil, dry_run: nil, yes: false)
      _ = yes
      validate_mount!
      retention_days ||= @wal_config.fetch('base_backup_retention_days').to_i
      minimum ||= @wal_config.fetch('minimum_base_backups').to_i
      dry_run = @runner.dry_run if dry_run.nil?
      complete = base_backups.reject { |backup| backup[:partial] }.sort_by { |backup| backup[:created_at] || '' }
      cutoff = Time.now - (retention_days.to_i * 86_400)
      deletable = complete.select { |backup| backup[:created_at] && Time.parse(backup[:created_at]) < cutoff }
      protected_count = [minimum.to_i, 0].max
      max_delete = [complete.length - protected_count, 0].max
      deletable = deletable.first(max_delete)

      puts "base_backup_directory: #{base_backup_directory}"
      puts "retention_days: #{retention_days}"
      puts "minimum_base_backups: #{minimum}"
      puts 'WAL archive pruning is not automatic in this implementation; do not delete WAL by age alone.'
      if deletable.empty?
        puts 'No base backups are eligible for deletion.'
        return
      end
      deletable.each do |backup|
        if dry_run
          puts "[DRY-RUN] remove #{backup[:path]}"
        else
          @runner.run('rm', '-rf', backup[:path])
          puts "[OK] removed #{backup[:path]}"
        end
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
        [[ "$wal_name" != *$'\\n'* && "$wal_name" != *$'\\r'* ]] || fail "invalid WAL filename"
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
        cmp --silent -- "$source_path" "$temporary" || fail "temporary WAL differs from source"
        sync -f "$temporary" || true
        mv -T -- "$temporary" "$destination"
        temporary=""
        sync -f "$destination" || true
        sync -f "$archive_dir" || true
        cmp --silent -- "$source_path" "$destination" || fail "copied WAL differs from source"
      BASH
    end

    private

    def current_settings(cluster)
      {
        'data_directory' => show_setting(cluster, 'data_directory'),
        'config_file' => show_setting(cluster, 'config_file'),
        'hba_file' => show_setting(cluster, 'hba_file'),
        'wal_level' => show_setting(cluster, 'wal_level'),
        'archive_mode' => show_setting(cluster, 'archive_mode'),
        'archive_command' => show_setting(cluster, 'archive_command'),
        'archive_timeout' => show_setting(cluster, 'archive_timeout'),
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
        SELECT archived_count, failed_count, COALESCE(last_archived_wal, ''), COALESCE(last_archived_time::text, ''), COALESCE(last_failed_wal, ''), COALESCE(last_failed_time::text, ''), COALESCE(stats_reset::text, '')
        FROM pg_stat_archiver;
      SQL
      values = output.strip.split('|', -1)
      keys = %w[archived_count failed_count last_archived_wal last_archived_time last_failed_wal last_failed_time stats_reset]
      Hash[keys.zip(values)]
    end

    def validate_mount!
      @runner.run('findmnt', '--target', mount_point)
      raise ValidationError, "#{mount_point} is not a directory" if !@runner.dry_run && !File.directory?(mount_point)
    end

    def mounted?
      @runner.run('findmnt', '--target', mount_point, allow_failure: true).success?
    end

    def prepare_directories!
      @runner.run('install', '-d', '-o', 'postgres', '-g', 'postgres', '-m', '0700', root_directory)
      if !@runner.dry_run && File.exist?(archive_directory) && !File.directory?(archive_directory)
        raise ValidationError, "archive directory path exists but is not a directory: #{archive_directory}"
      end
      if !@runner.dry_run && File.symlink?(archive_directory)
        raise ValidationError, "archive directory must not be a symlink: #{archive_directory}"
      end
      @runner.run('install', '-d', '-o', 'postgres', '-g', 'postgres', '-m', '0700', archive_directory)
      @runner.run('install', '-d', '-o', 'postgres', '-g', 'postgres', '-m', '0700', base_backup_directory)
      @runner.run('install', '-d', '-o', 'root', '-g', 'postgres', '-m', '0750', scripts_directory)
      @runner.run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', File.dirname(archive_script))
      @runner.run('sudo', '-u', 'postgres', 'test', '-w', archive_directory)
      @runner.run('sudo', '-u', 'postgres', 'test', '-w', base_backup_directory)
    end

    def install_archive_script!
      install_file_if_changed(archive_script, archive_script_content, owner: 'root', group: 'root', mode: '0755',
                              validate: ['bash', '-n'])
    end

    def install_postgresql_config!(cluster, settings)
      changed = false
      desired = {
        'wal_level' => EXPECTED_WAL_LEVEL,
        'archive_mode' => EXPECTED_ARCHIVE_MODE,
        'archive_command' => archive_command,
        'archive_timeout' => archive_timeout
      }
      desired.each do |name, value|
        next if settings.fetch(name).to_s == value.to_s

        run_alter_system(cluster, name, value)
        changed = true
      end
      validate_postgresql_config!(cluster)
      changed
    rescue StandardError
      restore_file_snapshot(@config_path, @last_config_snapshot)
      raise
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
      @runner.run('sudo', '-u', 'postgres', postgres_binary(cluster), '-D',
                  current_settings(cluster).fetch('data_directory'), '-C', 'archive_mode')
    end

    def restart_required?(settings, script_changed:, config_changed:)
      _ = script_changed
      config_changed ||
        settings.fetch('wal_level') != EXPECTED_WAL_LEVEL ||
        settings.fetch('archive_mode') != 'on' ||
        settings.fetch('archive_command') != archive_command ||
        settings.fetch('archive_timeout') != archive_timeout
    end

    def verify_runtime!(cluster)
      settings = current_settings(cluster)
      raise Error, "wal_level is #{settings.fetch('wal_level')}, expected #{EXPECTED_WAL_LEVEL}" unless settings.fetch('wal_level') == EXPECTED_WAL_LEVEL
      raise Error, "archive_mode is #{settings.fetch('archive_mode')}, expected on" unless settings.fetch('archive_mode') == 'on'
      unless settings.fetch('archive_command') == archive_command
        raise Error, "archive_command is #{settings.fetch('archive_command')}, expected #{archive_command}"
      end
      unless settings.fetch('archive_timeout') == archive_timeout
        raise Error, "archive_timeout is #{settings.fetch('archive_timeout')}, expected #{archive_timeout}"
      end
      library = settings.fetch('archive_library')
      raise Error, "archive_library is #{library}, expected empty" unless library.empty?
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

    def postgres_binary(cluster)
      versioned = File.join('/usr/lib/postgresql', cluster.version, 'bin', 'postgres')
      return versioned if File.executable?(versioned)

      'postgres'
    end

    def apply_root_directory!(root)
      @wal_config['root_directory'] = root
      @wal_config['archive_directory'] = File.join(root, 'wal-archive')
      @wal_config['base_backup_directory'] = File.join(root, 'base-backups')
      @wal_config['scripts_directory'] = File.join(root, 'scripts')
    end

    def run_alter_system(cluster, name, value)
      escaped = value.to_s.gsub("'", "''")
      psql(cluster, "ALTER SYSTEM SET #{name} = '#{escaped}';")
    end

    def backup_auto_conf!(settings)
      path = File.join(settings.fetch('data_directory'), 'postgresql.auto.conf')
      @config_path = path
      @last_config_snapshot = file_snapshot(path)
      return if @runner.dry_run || !File.exist?(path)

      backup = "#{path}.mitsubachi-backup.#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
      @runner.run('cp', '-a', path, backup)
    end

    def verify_base_backup!(path)
      available = @runner.run('which', 'pg_verifybackup', allow_failure: true)
      unless available.success?
        @logger.puts('[WARN] pg_verifybackup is not available; base backup manifest verification was skipped.')
        return
      end
      result = @runner.run('pg_verifybackup', path, allow_failure: true)
      return if result.success?

      raise Error, "pg_verifybackup failed for #{path}: #{result.stderr}"
    end

    def base_backups
      return [] unless File.directory?(base_backup_directory)

      Dir.children(base_backup_directory).sort.filter_map do |name|
        path = File.join(base_backup_directory, name)
        next unless File.directory?(path)

        partial = name.end_with?('.partial')
        backup_name = partial ? name.delete_suffix('.partial') : name
        next unless backup_name.match?(/\A\d{4}-\d{2}-\d{2}T\d{6}[+-]\d{4}\z/)

        metadata_path = File.join(path, 'mitsubachi-backup.json')
        metadata = File.file?(metadata_path) ? JSON.parse(File.read(metadata_path)) : {}
        {
          name: name,
          path: path,
          partial: partial,
          created_at: metadata['started_at'] || timestamp_to_iso8601(backup_name),
          bytes: directory_bytes(path)
        }
      end
    end

    def timestamp_to_iso8601(value)
      Time.strptime(value, '%Y-%m-%dT%H%M%S%z').iso8601
    rescue ArgumentError
      nil
    end

    def directory_stats(path)
      return { count: 0, bytes: 0, last_modified: nil } unless File.directory?(path)

      files = Dir.children(path).filter_map do |name|
        child = File.join(path, name)
        File.file?(child) && !File.symlink?(child) ? child : nil
      end
      latest = files.map { |file| File.mtime(file) }.max
      { count: files.length, bytes: files.sum { |file| File.size(file) }, last_modified: latest&.iso8601 }
    end

    def directory_bytes(path)
      return 0 unless File.directory?(path)

      Dir.glob(File.join(path, '**', '*'), File::FNM_DOTMATCH).sum do |file|
        next 0 if %w[. ..].include?(File.basename(file))
        next 0 unless File.file?(file)

        File.size(file)
      end
    end

    def mount_status
      { mounted: mounted? }
    end

    def free_capacity(path)
      line = command_stdout('df', '-P', path, allow_failure: true).lines.last.to_s.strip
      used_percent = line[/\s(\d+)%\s/, 1].to_i
      { line: line, available_percent: used_percent.zero? ? nil : 100 - used_percent }
    end

    def status_state(settings, archiver, mount_stats, free)
      return 'DISABLED' unless settings.fetch('archive_mode') == 'on'
      return 'ERROR' unless mount_stats[:mounted]
      return 'ERROR' if free[:available_percent] && free[:available_percent] < 5
      return 'ERROR' unless settings.fetch('archive_command') == archive_command
      return 'WARNING' if free[:available_percent] && free[:available_percent] < 10
      return 'WARNING' if archiver['last_failed_time'].to_s > archiver['last_archived_time'].to_s
      return 'WARNING' unless settings.fetch('wal_level') == EXPECTED_WAL_LEVEL
      return 'WARNING' unless settings.fetch('archive_timeout') == archive_timeout

      'OK'
    end

    def path_owner(path)
      return '(missing)' unless File.exist?(path)

      stat = File.stat(path)
      "#{stat.uid}:#{stat.gid}"
    end

    def path_mode(path)
      return '(missing)' unless File.exist?(path)

      format('%04o', File.stat(path).mode & 0o777)
    end

    def mount_point
      @wal_config.fetch('mount_point')
    end

    def root_directory
      @wal_config.fetch('root_directory')
    end

    def archive_directory
      @wal_config.fetch('archive_directory')
    end

    def base_backup_directory
      @wal_config.fetch('base_backup_directory')
    end

    def scripts_directory
      @wal_config.fetch('scripts_directory')
    end

    def archive_script
      @wal_config.fetch('archive_script')
    end

    def archive_timeout
      @wal_config.fetch('archive_timeout').to_s.empty? ? '300s' : @wal_config.fetch('archive_timeout').to_s
    end
  end
end
