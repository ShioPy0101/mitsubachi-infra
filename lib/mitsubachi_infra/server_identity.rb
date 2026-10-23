# frozen_string_literal: true

require 'securerandom'
require 'yaml'
require_relative 'atomic_writer'
require_relative 'errors'

module MitsubachiInfra
  # サーバー識別情報の初回登録・片側欠落の補完を担当する。
  # 呼び出し元は infra 共通 Lock の内側で実行し、同時初期登録を防ぐ。
  # 登録済みの不一致は別ホストへの誤適用を示すため、自動的に揃えてはならない。
  class ServerIdentity
    def initialize(config:, runner:, logger:, writer: AtomicWriter.new(runner: runner))
      @config = config
      @runner = runner
      @logger = logger
      @writer = writer
    end

    def ensure!
      expected = @config.fetch('server')['server_id'].to_s.strip
      path = @config.fetch('paths').fetch('server_id')
      if (File.exist?(path) || File.symlink?(path)) && !File.file?(path)
        raise ValidationError, "server identity path is not a regular file: #{path}"
      end
      actual = File.file?(path) ? File.read(path).strip : ''
      if !expected.empty? && !actual.empty? && expected != actual
        raise ValidationError, "server ID mismatch: expected #{expected}, got #{actual}"
      end
      return expected unless expected.empty? || actual.empty?

      if @runner.dry_run
        @logger.puts('[DRY-RUN] register missing server identity in config and identity file')
        return
      end

      # config 保存前に識別ファイルを永続化する。途中で失敗しても次回はその ID を
      # 引き継ぎ、再実行で別の UUID が生成されないようにする。
      document = load_config if expected.empty?
      id = [expected, actual].find { |value| !value.empty? } || SecureRandom.uuid
      @writer.write(path, "#{id}\n", owner: 'root', group: 'root', mode: '0644') if actual.empty?
      if expected.empty?
        document['server'] ||= {}
        document.fetch('server')['server_id'] = id
        stat = File.stat(@config.path)
        @writer.write(@config.path, document.to_yaml, owner: stat.uid.to_s, group: stat.gid.to_s, mode: '0640')
        @config.set('server.server_id', id)
      end
      @logger.puts('[LOCAL] registered missing server identity')
      id
    rescue SystemCallError => e
      raise Error, "server identity registration failed: #{e.message}; run sudo mitsubachi-infra production-check"
    end

    private

    def load_config
      document = YAML.safe_load(File.read(@config.path), permitted_classes: [], aliases: false) || {}
      unless document.is_a?(Hash) && (document['server'].nil? || document['server'].is_a?(Hash))
        raise ValidationError, 'server identity requires a mapping in config.yml and server'
      end

      document
    end
  end
end
