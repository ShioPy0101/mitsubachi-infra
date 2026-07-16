# frozen_string_literal: true

require 'English'
require 'erb'
require 'fileutils'

module MitsubachiInfra
  class Nginx
    def initialize(config:, runner:, repo_root:)
      @config = config
      @runner = runner
      @repo_root = repo_root
    end

    def render(mode:)
      template = File.read(File.join(@repo_root, 'templates', 'nginx', "#{mode}.conf.erb"))
      ERB.new(template, trim_mode: '-').result(binding)
    end

    def install(mode:)
      content = render(mode: mode)
      target = '/etc/nginx/sites-available/mitsubachi.conf'
      tmp = "/tmp/mitsubachi-nginx-#{$PROCESS_ID}.conf"
      File.write(tmp, content)
      @runner.run('install', '-o', 'root', '-g', 'root', '-m', '0644', tmp, target)
      @runner.run('ln', '-sfn', target, '/etc/nginx/sites-enabled/mitsubachi.conf')
      test!
      reload
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
  end
end
