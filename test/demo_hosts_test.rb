# frozen_string_literal: true
require 'minitest/autorun'
require 'stringio'
require 'erb'
require_relative '../lib/mitsubachi_infra/configuration'
require_relative '../lib/mitsubachi_infra/nginx'
require_relative '../lib/mitsubachi_infra/deployment/release'

class DemoHostsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def config(enabled)
    MitsubachiInfra::Configuration.new('/missing', data: {
      'deployment_mode' => 'public', 'https' => { 'email' => 'ops@example.com' },
      'demo' => { 'enabled' => enabled }
    })
  end

  def test_デモ無効時は公開ホストも証明書対象も増えない
    value = config(false)
    assert_equal 2, value.certificate_domains.size
    text = MitsubachiInfra::Nginx.new(config: value, runner: nil, repo_root: ROOT).render(mode: 'public_https')
    refute_includes text, 'server_name demo.mitsubachi.shiosalt.com;'
  end

  def test_デモ専用ホストは別Pumaに接続し実ファイル配信を持たない
    value = config(true)
    assert_equal 4, value.certificate_domains.size
    text = MitsubachiInfra::Nginx.new(config: value, runner: nil, repo_root: ROOT).render(mode: 'public_https')
    demo = text.split('# デモは専用ホスト').last
    assert_includes demo, 'server_name demo.mitsubachi.shiosalt.com;'
    assert_includes demo, 'server_name mitsubachi-demo-api.shiosalt.com;'
    assert_includes demo, 'proxy_pass http://127.0.0.1:3002;'
    assert_includes demo, 'location / { return 404; }'
    refute_includes demo, 'internal/storage'
    assert_includes demo, 'client_max_body_size 16k;'
  end

  def test_デモプロセスは専用環境とストレージ分離を指定する
    @config = config(true)
    text = ERB.new(File.read(File.join(ROOT, 'templates/systemd/mitsubachi-demo-api.service.erb'))).result(binding)
    assert_includes text, 'EnvironmentFile=/etc/mitsubachi/demo-rails.env'
    assert_includes text, 'Environment=DEMO_MODE=true'
    assert_includes text, 'Environment=FEATURE_DEMO_TENANT=true'
    assert_includes text, 'Environment=APP_HOSTS=mitsubachi-demo-api.shiosalt.com'
    assert_includes text, 'tcp://127.0.0.1:3002'
    assert_includes text, 'InaccessiblePaths=-/mnt/external-hdd/mitsubachi/files'
    assert_includes text, 'UnsetEnvironment=SOLID_QUEUE_IN_PUMA'
  end

  def test_デモ有効時だけリリースと失敗時の復旧で専用サービスも再起動する
    commands = []
    runner = Object.new
    runner.define_singleton_method(:run) { |*command, **_options| commands << command }
    release = MitsubachiInfra::Deployment::Release.allocate
    release.instance_variable_set(:@runner, runner)
    release.instance_variable_set(:@config, config(true))
    release.send(:restart_services)
    assert_includes commands, ['systemctl', 'restart', 'mitsubachi-demo-api.service']
    assert_includes commands, ['systemctl', 'is-active', '--quiet', 'mitsubachi-demo-api.service']
    commands.clear
    release.send(:restart_services, allow_failure: true)
    assert_includes commands, ['systemctl', 'restart', 'mitsubachi-demo-api.service']
    commands.clear
    release.instance_variable_set(:@config, config(false))
    release.send(:restart_services)
    refute commands.flatten.include?('mitsubachi-demo-api.service')
  end

  def test_通常APIと同じポートは利用できない
    assert_raises(MitsubachiInfra::ValidationError) do
      MitsubachiInfra::Configuration.new('/missing', data: {
        'deployment_mode' => 'public', 'https' => { 'email' => 'ops@example.com' },
        'demo' => { 'enabled' => true, 'api_port' => 3000 }
      })
    end
  end
end
