# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/mitsubachi_infra/configuration'
require_relative '../lib/mitsubachi_infra/frontend_env'

class DemoFlagsTest < Minitest::Test
  def test_配信設定が有効な時だけフロントのデモ導線を有効にする
    Dir.mktmpdir do |root|
      path = File.join(root, 'frontend.env')
      File.write(path, "VITE_API_BASE_URL=https://mitsubachi-api.shiosalt.com\n")
      [false, true].each do |enabled|
        config = MitsubachiInfra::Configuration.new('/missing', data: {
          'deployment_mode' => 'public', 'https' => { 'email' => 'ops@example.com' },
          'demo' => { 'enabled' => enabled }
        })
        env = MitsubachiInfra::FrontendEnv.new(config: config, path: path).build_env
        enabled ? assert_equal('true', env['VITE_FEATURE_DEMO_TENANT']) : assert_nil(env['VITE_FEATURE_DEMO_TENANT'])
        File.write(path, "VITE_API_BASE_URL=https://mitsubachi-api.shiosalt.com\nVITE_FEATURE_DEMO_TENANT=false\n")
        actual = MitsubachiInfra::FrontendEnv.new(config: config, path: path).build_env['VITE_FEATURE_DEMO_TENANT']
        enabled ? assert_equal('false', actual) : assert_nil(actual)
        File.write(path, "VITE_API_BASE_URL=https://mitsubachi-api.shiosalt.com\n")
      end
    end
  end
end
