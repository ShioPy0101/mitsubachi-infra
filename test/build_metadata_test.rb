# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/mitsubachi_infra/deployment/build_metadata'

class BuildMetadataTest < Minitest::Test
  def test_ビルドと本番反映の日時を別に保持する
    Dir.mktmpdir do |release|
      %w[backend frontend].each do |component|
        options = { release: release, component: component }
        MitsubachiInfra::Deployment::BuildMetadata.write(**options, sha: 'a' * 40, built_at: '2026-10-23T00:00:00Z')
        MitsubachiInfra::Deployment::BuildMetadata.mark_deployed(**options, at: '2026-10-23T01:00:00Z')
        path = component == 'frontend' ? File.join(release, 'dist/release-info.json') : File.join(release, 'build-info.json')
        info = JSON.parse(File.read(path))
        assert_equal 'a' * 40, info.fetch('commit')
        assert_equal '2026-10-23T00:00:00Z', info.fetch('built_at')
        assert_equal '2026-10-23T01:00:00Z', info.fetch('deployed_at')
      end
    end
  end

  def test_dry_runでは成果物を書き換えない
    Dir.mktmpdir do |release|
      MitsubachiInfra::Deployment::BuildMetadata.write(release: release, component: 'backend', sha: 'a' * 40, dry_run: true)
      assert_empty Dir.children(release)
    end
  end
end
