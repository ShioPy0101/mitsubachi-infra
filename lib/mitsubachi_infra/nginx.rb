# frozen_string_literal: true

require 'English'
require 'erb'
require 'fileutils'

module MitsubachiInfra
  class Nginx
    NGINX_CONF = '/etc/nginx/nginx.conf'
    CONF_D = '/etc/nginx/conf.d'
    SITES_ENABLED = '/etc/nginx/sites-enabled'
    TARGET = '/etc/nginx/sites-available/mitsubachi.conf'
    ENABLED = '/etc/nginx/sites-enabled/mitsubachi.conf'
    UBUNTU_DEFAULT = '/etc/nginx/sites-enabled/default'

    DEFAULT_SERVER_PATTERN = /\blisten\s+(?<address>(?:\[::\]:)?80)\s+[^;]*\bdefault_server\b[^;]*;/i

    def initialize(config:, runner:, repo_root:, logger: $stderr, nginx_conf: NGINX_CONF, conf_d: CONF_D,
                   sites_enabled: SITES_ENABLED, target: TARGET, enabled: ENABLED, ubuntu_default: UBUNTU_DEFAULT)
      @config = config
      @runner = runner
      @repo_root = repo_root
      @logger = logger
      @nginx_conf = nginx_conf
      @conf_d = conf_d
      @sites_enabled = sites_enabled
      @target = target
      @enabled = enabled
      @ubuntu_default = ubuntu_default
    end

    def render(mode:)
      template = File.read(File.join(@repo_root, 'templates', 'nginx', "#{mode}.conf.erb"))
      ERB.new(template, trim_mode: '-').result(binding)
    end

    def install(mode:, remove_default_site: remove_default_site?)
      inspect_existing!(remove_default_site: remove_default_site)
      content = render(mode: mode)
      tmp = "/tmp/mitsubachi-nginx-#{$PROCESS_ID}.conf"
      File.write(tmp, content)
      validate_candidate_defaults!(tmp, remove_default_site: remove_default_site)
      safe_apply(tmp, remove_default_site: remove_default_site)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    def test!
      @runner.run('nginx', '-t')
    end

    def reload
      @runner.run('systemctl', 'reload', 'nginx')
    end

    private

    attr_reader :config

    def safe_apply(source, remove_default_site:)
      backup = backup_path
      previous_link = readlink(@enabled)
      default_link = readlink(@ubuntu_default)
      had_target = exist_or_symlink?(@target)
      had_enabled = exist_or_symlink?(@enabled)
      had_default = exist_or_symlink?(@ubuntu_default)
      backup_existing(backup) if had_target

      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0644', source, @target)
      remove_ubuntu_default_site if remove_default_site
      @runner.run('ln', '-sfn', @target, @enabled)
      test!
      reload
    rescue StandardError => original_error
      restore(target_backup: backup, had_target: had_target, had_enabled: had_enabled,
              previous_link: previous_link, had_default: had_default, default_link: default_link,
              original_error: original_error)
      raise
    ensure
      FileUtils.rm_f(backup) if backup && File.exist?(backup)
    end

    def backup_existing(backup)
      @runner.run('cp', '-a', @target, backup)
    end

    def restore(target_backup:, had_target:, had_enabled:, previous_link:, had_default:, default_link:, original_error:)
      actions = []
      if had_target && File.exist?(target_backup)
        @runner.run('cp', '-a', target_backup, @target, allow_failure: true)
        actions << "restored #{@target} from #{target_backup}"
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

    def backup_path
      "/tmp/mitsubachi-nginx-rollback-#{$PROCESS_ID}.conf"
    end

    def default_server_suffix
      default_server? ? ' default_server' : ''
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
