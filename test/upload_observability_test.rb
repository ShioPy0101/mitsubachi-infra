# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

class UploadObservabilityTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_nginx_upload_log_is_json_and_sanitizes_session_id
    logging = File.read(File.join(ROOT, 'templates/nginx/conf.d/mitsubachi-logging.conf.erb'))
    assert_includes logging, 'log_format mitsubachi_upload_json escape=json'
    assert_includes logging, 'map $http_x_upload_session_id $mitsubachi_upload_session_id'
    assert_includes logging, '"uri":"$uri"'
    refute_includes logging, '$request_uri'
    refute_includes logging, '$http_authorization'
    refute_includes logging, '$http_cookie'
  end

  def test_capture_script_has_signal_cleanup_and_missing_command_fallback
    script = File.read(File.join(ROOT, 'bin/capture-upload-load'))
    assert_includes script, 'trap cleanup INT TERM EXIT'
    assert_includes script, 'command unavailable:'
    assert_includes script, 'child-pids.txt'
    assert_includes script, 'snapshot before'
    assert_includes script, 'snapshot after'
  end

  def test_capture_script_rejects_invalid_uuid_without_creating_output
    Dir.mktmpdir do |dir|
      result = system(File.join(ROOT, 'bin/capture-upload-load'), '--session-id', "bad\nid", '--output-dir', dir,
                      out: File::NULL, err: File::NULL)
      refute result
      assert_empty Dir.children(dir)
    end
  end
end
