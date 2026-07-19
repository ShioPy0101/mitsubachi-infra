# frozen_string_literal: true

require 'English'
require 'erb'
require 'fileutils'
require 'time'

module MitsubachiInfra
  class Nginx
    NGINX_CONF = '/etc/nginx/nginx.conf'
    CONF_D = '/etc/nginx/conf.d'
    LOGGING_CONF = '/etc/nginx/conf.d/mitsubachi-logging.conf'
    SITES_ENABLED = '/etc/nginx/sites-enabled'
    TARGET = '/etc/nginx/sites-available/mitsubachi.conf'
    ENABLED = '/etc/nginx/sites-enabled/mitsubachi.conf'
    UBUNTU_DEFAULT = '/etc/nginx/sites-enabled/default'
    BACKUP_ROOT = '/var/lib/mitsubachi-infra/backups/nginx'

    DEFAULT_SERVER_PATTERN = /\blisten\s+(?<address>(?:\[::\]:)?80)\s+[^;]*\bdefault_server\b[^;]*;/i

    def initialize(config:, runner:, repo_root:, logger: $stderr, nginx_conf: NGINX_CONF, conf_d: CONF_D,
                   logging_conf: LOGGING_CONF, sites_enabled: SITES_ENABLED, target: TARGET, enabled: ENABLED,
                   ubuntu_default: UBUNTU_DEFAULT, backup_root: BACKUP_ROOT)
      @config = config
      @runner = runner
      @repo_root = repo_root
      @logger = logger
      @nginx_conf = nginx_conf
      @conf_d = conf_d
      @logging_conf = logging_conf
      @sites_enabled = sites_enabled
      @target = target
      @enabled = enabled
      @ubuntu_default = ubuntu_default
      @backup_root = backup_root
    end

    def render(mode:)
      template = File.read(File.join(@repo_root, 'templates', 'nginx', "#{mode}.conf.erb"))
      ERB.new(template, trim_mode: '-').result(binding)
    end

    def render_nginx_conf
      template = File.read(File.join(@repo_root, 'templates', 'nginx', 'nginx.conf.erb'))
      ERB.new(template, trim_mode: '-').result(binding)
    end

    def render_logging_conf
      template = File.read(File.join(@repo_root, 'templates', 'nginx', 'conf.d', 'mitsubachi-logging.conf.erb'))
      ERB.new(template, trim_mode: '-').result(binding)
    end

    def install(mode:, remove_default_site: remove_default_site?)
      inspect_existing!(remove_default_site: remove_default_site)
      site_tmp = write_tmp('site', render(mode: mode))
      nginx_conf_tmp = write_tmp('nginx', render_nginx_conf)
      logging_tmp = write_tmp('logging', render_logging_conf)
      validate_candidate_defaults!(site_tmp, remove_default_site: remove_default_site)
      safe_apply(site_tmp: site_tmp, nginx_conf_tmp: nginx_conf_tmp, logging_tmp: logging_tmp,
                 remove_default_site: remove_default_site)
    ensure
      [site_tmp, nginx_conf_tmp, logging_tmp].compact.each { |tmp| FileUtils.rm_f(tmp) }
    end

    def test!
      @runner.run('nginx', '-t')
    end

    def test_result
      @runner.run('nginx', '-t', allow_failure: true)
    end

    def reload
      @runner.run('systemctl', 'reload', 'nginx')
    end

    private

    attr_reader :config

    def safe_apply(site_tmp:, nginx_conf_tmp:, logging_tmp:, remove_default_site:)
      changes = planned_changes(site_tmp: site_tmp, nginx_conf_tmp: nginx_conf_tmp, logging_tmp: logging_tmp,
                                remove_default_site: remove_default_site)
      if changes.empty?
        @logger.puts('[NGINX] configuration already matches rendered templates; skipping write, backup, and reload')
        return
      end

      @logger.puts("[NGINX] applying changes: #{changes.join(', ')}")
      log_diff(@nginx_conf, nginx_conf_tmp) if changes.include?('nginx.conf')
      log_diff(@logging_conf, logging_tmp) if changes.include?('logging')
      log_diff(@target, site_tmp) if changes.include?('site')

      site_backup = rollback_backup_path('site')
      logging_backup = rollback_backup_path('logging')
      staged_nginx_conf = "#{@nginx_conf}.mitsubachi-#{$PROCESS_ID}.tmp"
      permanent_backup_dir = nil
      previous_link = readlink(@enabled)
      default_link = readlink(@ubuntu_default)
      had_nginx_conf = exist_or_symlink?(@nginx_conf)
      had_logging = exist_or_symlink?(@logging_conf)
      had_target = exist_or_symlink?(@target)
      had_enabled = exist_or_symlink?(@enabled)
      had_default = exist_or_symlink?(@ubuntu_default)

      permanent_backup_dir = backup_nginx_conf if changes.include?('nginx.conf') && had_nginx_conf
      backup_existing(@target, site_backup) if changes.include?('site') && had_target
      backup_existing(@logging_conf, logging_backup) if changes.include?('logging') && had_logging

      install_file(logging_tmp, @logging_conf) if changes.include?('logging')
      install_file(site_tmp, @target) if changes.include?('site')
      remove_ubuntu_default_site if changes.include?('default-site')
      @runner.run('ln', '-sfn', @target, @enabled) if changes.include?('enabled-link')
      install_file(nginx_conf_tmp, staged_nginx_conf) if changes.include?('nginx.conf')

      if changes.include?('nginx.conf')
        @runner.run('nginx', '-t', '-c', staged_nginx_conf)
        @runner.run('mv', '-f', staged_nginx_conf, @nginx_conf)
      else
        test!
      end
      test!
      reload
    rescue StandardError => original_error
      restore(nginx_backup_dir: permanent_backup_dir, site_backup: site_backup, logging_backup: logging_backup,
              had_nginx_conf: had_nginx_conf, had_logging: had_logging, had_target: had_target,
              had_enabled: had_enabled, previous_link: previous_link, had_default: had_default,
              default_link: default_link, staged_nginx_conf: staged_nginx_conf, original_error: original_error)
      raise
    ensure
      [site_backup, logging_backup, staged_nginx_conf].compact.each { |path| FileUtils.rm_f(path) if File.exist?(path) }
    end

    def write_tmp(label, content)
      path = "/tmp/mitsubachi-nginx-#{label}-#{$PROCESS_ID}.conf"
      File.write(path, content)
      path
    end

    def planned_changes(site_tmp:, nginx_conf_tmp:, logging_tmp:, remove_default_site:)
      changes = []
      changes << 'nginx.conf' unless identical_content?(@nginx_conf, nginx_conf_tmp)
      changes << 'logging' unless identical_content?(@logging_conf, logging_tmp)
      changes << 'site' unless identical_content?(@target, site_tmp)
      changes << 'default-site' if remove_default_site && File.symlink?(@ubuntu_default)
      changes << 'enabled-link' unless File.symlink?(@enabled) && File.readlink(@enabled) == @target
      changes
    end

    def identical_content?(path, candidate)
      File.exist?(path) && File.file?(path) && File.read(path) == File.read(candidate)
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def log_diff(path, candidate)
      return unless File.exist?(path) || File.symlink?(path)

      @runner.run('diff', '-u', path, candidate, allow_failure: true)
    end

    def install_file(source, target)
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0644', source, target)
    end

    def backup_existing(source, backup)
      @runner.run('cp', '-a', source, backup)
    end

    def backup_nginx_conf
      stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
      backup_dir = File.join(@backup_root, stamp)
      @runner.run('install', '-d', '-o', 'root', '-g', 'root', '-m', '0755', backup_dir)
      @runner.run('cp', '-a', @nginx_conf, File.join(backup_dir, 'nginx.conf'))
      backup_dir
    end

    def restore(nginx_backup_dir:, site_backup:, logging_backup:, had_nginx_conf:, had_logging:, had_target:,
                had_enabled:, previous_link:, had_default:, default_link:, staged_nginx_conf:, original_error:)
      actions = []
      if had_nginx_conf && nginx_backup_dir
        @runner.run('cp', '-a', File.join(nginx_backup_dir, 'nginx.conf'), @nginx_conf, allow_failure: true)
        actions << "restored #{@nginx_conf} from #{nginx_backup_dir}"
      elsif !had_nginx_conf
        @runner.run('rm', '-f', @nginx_conf, allow_failure: true)
        actions << "removed newly-created #{@nginx_conf}"
      end

      @runner.run('rm', '-f', staged_nginx_conf, allow_failure: true) if staged_nginx_conf

      if had_logging && File.exist?(logging_backup)
        @runner.run('cp', '-a', logging_backup, @logging_conf, allow_failure: true)
        actions << "restored #{@logging_conf} from #{logging_backup}"
      elsif !had_logging
        @runner.run('rm', '-f', @logging_conf, allow_failure: true)
        actions << "removed newly-created #{@logging_conf}"
      else
        actions << "skipped #{@logging_conf} restore because backup was missing"
      end

      if had_target && File.exist?(site_backup)
        @runner.run('cp', '-a', site_backup, @target, allow_failure: true)
        actions << "restored #{@target} from #{site_backup}"
      elsif !had_target
        @runner.run('rm', '-f', @target, allow_failure: true)
        actions << "removed newly-created #{@target}"
      else
        actions << "skipped #{@target} restore because backup was missing"
      end

      if had_enabled && previous_link
        @runner.run('ln', '-sfn', previous_link, @enabled, allow_failure: true)
        actions << "recreated symlink #{@enabled} -> #{previous_link}"
      elsif !had_enabled
        @runner.run('rm', '-f', @enabled, allow_failure: true)
        actions << "removed newly-created #{@enabled}"
      else
        actions << "left #{@enabled} unchanged because previous symlink target was unknown"
      end

      if had_default && default_link
        @runner.run('ln', '-sfn', default_link, @ubuntu_default, allow_failure: true)
        actions << "recreated symlink #{@ubuntu_default} -> #{default_link}"
      elsif !had_default
        actions << "left #{@ubuntu_default} absent"
      else
        actions << "left #{@ubuntu_default} unchanged because previous symlink target was unknown"
      end

      result = @runner.run('nginx', '-t', allow_failure: true)
      return if result.success?

      raise Error, [
        'nginx rollback failed',
        "original_error=#{original_error.message}",
        "rollback_actions=#{actions.join('; ')}",
        "rollback_stdout=#{@runner.mask(result.stdout)}",
        "rollback_stderr=#{@runner.mask(result.stderr)}"
      ].join("\n")
    end

    def inspect_existing!(remove_default_site:)
      log_existing_state(remove_default_site: remove_default_site)
      result = @runner.run('nginx', '-t', allow_failure: true)
      return if result.success?

      raise Error, [
        'existing Nginx configuration is broken; refusing to install mitsubachi.conf',
        "stdout=#{@runner.mask(result.stdout)}",
        "stderr=#{@runner.mask(result.stderr)}"
      ].join("\n")
    end

    def log_existing_state(remove_default_site:)
      defaults = default_server_locations(existing_nginx_files)
      @logger.puts("[NGINX] default_server locations: #{defaults.empty? ? '(none)' : defaults.join(', ')}")
      @logger.puts("[NGINX] #{@nginx_conf} exists: #{exist_or_symlink?(@nginx_conf)}")
      @logger.puts("[NGINX] #{@logging_conf} exists: #{exist_or_symlink?(@logging_conf)}")
      @logger.puts("[NGINX] #{@target} exists: #{exist_or_symlink?(@target)}")
      @logger.puts("[NGINX] #{@ubuntu_default} exists: #{exist_or_symlink?(@ubuntu_default)}")
      @logger.puts("[NGINX] remove default site: #{remove_default_site}")
    end

    def validate_candidate_defaults!(candidate, remove_default_site:)
      files = existing_nginx_files
      files = files.reject { |path| File.expand_path(path) == File.expand_path(@target) }
      files = files.reject { |path| File.expand_path(path) == File.expand_path(@enabled) }
      if remove_default_site && File.symlink?(@ubuntu_default)
        files = files.reject { |path| File.expand_path(path) == File.expand_path(@ubuntu_default) }
      end
      defaults = default_server_locations(files + [candidate])
      grouped = defaults.group_by { |entry| entry.split(' ', 2).first }
      duplicates = grouped.select { |_address, entries| entries.length > 1 }
      return if duplicates.empty?

      detail = duplicates.map { |address, entries| "#{address}: #{entries.join(', ')}" }.join('; ')
      raise Error, "Nginx default_server would be duplicated: #{detail}"
    end

    def default_server_locations(files)
      files.flat_map do |path|
        next [] unless File.file?(path)

        File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
          match = line.match(DEFAULT_SERVER_PATTERN)
          next unless match

          "#{normalize_default_address(match[:address])} #{path}:#{index + 1}"
        end
      rescue Errno::ENOENT, Errno::EACCES
        []
      end
    end

    def normalize_default_address(address)
      address.start_with?('[::]') ? '[::]:80' : '0.0.0.0:80'
    end

    def existing_nginx_files
      [@nginx_conf] + Dir.glob(File.join(@conf_d, '*')) + Dir.glob(File.join(@sites_enabled, '*'))
    end

    def remove_ubuntu_default_site
      @logger.puts("[NGINX] disabling #{@ubuntu_default} symlink if present")
      @runner.run('rm', '-f', @ubuntu_default) if File.symlink?(@ubuntu_default) || @runner.dry_run
    end

    def readlink(path)
      return nil unless File.symlink?(path)

      File.readlink(path)
    end

    def rollback_backup_path(label)
      "/tmp/mitsubachi-nginx-rollback-#{label}-#{$PROCESS_ID}.conf"
    end

    def default_server_suffix
      default_server? ? ' default_server' : ''
    end

    def nginx_error_log_level
      @config.fetch('nginx').fetch('error_log_level')
    end

    def default_server?
      @config.fetch('nginx').fetch('default_server')
    end

    def remove_default_site?
      @config.fetch('nginx').fetch('remove_default_site')
    end

    def exist_or_symlink?(path)
      File.exist?(path) || File.symlink?(path)
    end
  end
end
