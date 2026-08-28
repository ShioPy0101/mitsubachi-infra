#!/usr/bin/env bash
set -Eeuo pipefail

# このスクリプトは媒体 Preview の実行条件を確認するだけで、package や
# filesystem の状態を変更しない。systemd と同じ deploy user / PATH で実行する。
resolve_tool() {
  local label="$1"
  local configured="$2"

  if [[ "${configured}" == */* ]]; then
    [[ -x "${configured}" ]] || {
      printf 'ERROR: %s is not executable: %s\n' "${label}" "${configured}" >&2
      return 1
    }
    printf '%s\n' "${configured}"
    return 0
  fi

  command -v "${configured}" 2>/dev/null || {
    printf 'ERROR: %s is not installed or is outside PATH: %s\n' \
      "${label}" "${configured}" >&2
    return 1
  }
}

version_line() {
  local label="$1"
  local path="$2"
  shift 2
  local output

  output="$("${path}" "$@" 2>&1)" || {
    printf 'ERROR: %s exists but version check failed: %s\n' "${label}" "${path}" >&2
    return 1
  }
  printf '%s: %s\n' "${label}" "${output%%$'\n'*}"
}

ffmpeg_path="$(resolve_tool ffmpeg "${MEDIA_FFMPEG_PATH:-ffmpeg}")"
ffprobe_path="$(resolve_tool ffprobe "${MEDIA_FFPROBE_PATH:-ffprobe}")"
vips_path="$(resolve_tool vips "${MEDIA_VIPS_PATH:-vips}")"

version_line ffmpeg "${ffmpeg_path}" -version
version_line ffprobe "${ffprobe_path}" -version
version_line vips "${vips_path}" --version
