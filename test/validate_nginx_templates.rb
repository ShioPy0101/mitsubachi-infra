# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT, 'lib'))

require 'mitsubachi_infra/configuration'
require 'mitsubachi_infra/nginx'

nginx_binary = ENV.fetch('NGINX_BINARY', 'nginx')
mime_types = ENV['NGINX_MIME_TYPES'] || ['/etc/nginx/mime.types', '/opt/homebrew/etc/nginx/mime.types'].find { |path| File.file?(path) }
abort 'Nginxのmime.typesが見つかりません' unless mime_types

def run!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  return if status.success?

  warn stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  abort "失敗: #{command.join(' ')}"
end

def replace_runtime_paths(content, directory, certificate, certificate_key)
  content
    .gsub(%r{/var/log/nginx/[a-zA-Z0-9_.-]+}, File.join(directory, 'nginx-test.log'))
    .gsub(%r{/etc/letsencrypt/live/[^/]+/fullchain\.pem}, certificate)
    .gsub(%r{/etc/letsencrypt/live/[^/]+/privkey\.pem}, certificate_key)
end

Dir.mktmpdir('mitsubachi-nginx-ci-') do |root|
  certificate = File.join(root, 'certificate.pem')
  certificate_key = File.join(root, 'certificate-key.pem')
  run!('openssl', 'req', '-x509', '-nodes', '-newkey', 'rsa:2048', '-days', '1',
       '-subj', '/CN=localhost', '-keyout', certificate_key, '-out', certificate)

  cases = {
    'lan' => ['config.lan.yml', 'lan'],
    'public_http_challenge' => ['config.public.yml', 'public_http_challenge'],
    'public_https' => ['config.public.yml', 'public_https']
  }

  cases.each do |name, (fixture, mode)|
    directory = File.join(root, name)
    FileUtils.mkdir_p(directory)
    config = MitsubachiInfra::Configuration.new(File.join(ROOT, 'test', 'fixtures', fixture))
    renderer = MitsubachiInfra::Nginx.new(config: config, runner: nil, repo_root: ROOT)
    logging = replace_runtime_paths(renderer.render_logging_conf, directory, certificate, certificate_key)
    site = replace_runtime_paths(renderer.render(mode: mode), directory, certificate, certificate_key)
    File.write(File.join(directory, 'logging.conf'), logging)
    File.write(File.join(directory, 'site.conf'), site)
    File.write(File.join(directory, 'nginx.conf'), <<~NGINX)
      worker_processes 1;
      pid #{File.join(directory, 'nginx.pid')};
      error_log stderr notice;
      events { worker_connections 64; }
      http {
        include #{mime_types};
        default_type application/octet-stream;
        include #{File.join(directory, 'logging.conf')};
        include #{File.join(directory, 'site.conf')};
      }
    NGINX
    run!(nginx_binary, '-t', '-e', 'stderr', '-c', File.join(directory, 'nginx.conf'), '-p', directory)
    puts "OK: #{name}"
  end
end
