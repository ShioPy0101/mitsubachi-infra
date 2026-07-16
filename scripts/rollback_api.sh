#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/rollback_api.sh [release-name] [options]

Options:
  --list                  List available releases and exit.
  --health-url URL        Ready health URL. Default: http://127.0.0.1:3000/api/health/ready.
  --health-host HOST      Host header for Rails health check.
  --skip-restart          Only switch current symlink; do not restart or health check.
  --help                  Show this help.
USAGE
}

TARGET=""
LIST=false
HEALTH_URL="http://127.0.0.1:3000/api/health/ready"
HEALTH_HOST="${HEALTH_HOST:-}"
SKIP_RESTART=false

while (($#)); do
  case "$1" in
    --list) LIST=true; shift ;;
    --health-url) HEALTH_URL="${2:-}"; shift 2 ;;
    --health-host) HEALTH_HOST="${2:-}"; shift 2 ;;
    --skip-restart) SKIP_RESTART=true; shift ;;
    --help) usage; exit 0 ;;
    --*) die "unknown argument: $1" ;;
    *) [[ -z "${TARGET}" ]] || die "only one release name may be specified"; TARGET="$1"; shift ;;
  esac
done

require_not_root
require_command find sort readlink flock
with_lock "rollback-api"

set_stage "preflight"
# rollback は current symlink を過去 release へ戻すだけで、DB migration の down
# は実行しない。production migration は後方互換を前提に設計する必要がある。
log "Rails API rollback を開始します。DB migration は戻しません。"
require_mountpoint "${EXTERNAL_HDD}"
[[ -d "${RELEASE_ROOT}" ]] || die "release root missing: ${RELEASE_ROOT}"

list_releases() {
  find "${RELEASE_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -rn | awk '{print $2}'
}

if [[ "${LIST}" == true ]]; then
  log "release 一覧を表示します。current は readlink -f の実体 path です。"
  current="$(readlink -f -- "${CURRENT_LINK}" 2>/dev/null || true)"
  printf 'current: %s\n' "${current:-none}"
  list_releases
  exit 0
fi

current_release="$(readlink -f -- "${CURRENT_LINK}" 2>/dev/null || true)"
[[ -n "${current_release}" ]] || die "current release is not set"
if [[ -z "${TARGET}" ]]; then
  TARGET="$(list_releases | while IFS= read -r name; do
    candidate="$(readlink -f -- "${RELEASE_ROOT}/${name}")"
    [[ "${candidate}" != "${current_release}" ]] || continue
    printf '%s\n' "${name}"
    break
  done)"
fi
[[ -n "${TARGET}" ]] || die "no previous release found"
validate_safe_basename "${TARGET}"
target_dir="${RELEASE_ROOT}/${TARGET}"
[[ -d "${target_dir}" ]] || die "target release directory missing: ${target_dir}"
target_real="$(readlink -f -- "${target_dir}")"
release_root_real="$(readlink -f -- "${RELEASE_ROOT}")"
[[ "${target_real}" == "${release_root_real}/"* ]] || die "target release is outside release root"

log "現在の release: ${current_release}"
log "切り戻し先 release: ${target_real}"
atomic_symlink_switch "${target_real}" "${CURRENT_LINK}"

if [[ "${SKIP_RESTART}" != true ]]; then
  log "rollback 後に systemd service を再起動し、health check を実行します。"
  sudo -n systemctl restart "${SERVICE_NAME}.service" || die "failed to restart ${SERVICE_NAME}; current points to $(readlink -f -- "${CURRENT_LINK}")"
  health_check_retry "${HEALTH_URL}" 30 2 "${HEALTH_HOST}"
else
  log "--skip-restart 指定のため service restart と health check は実行しません。"
fi

printf '%s rollback from=%s to=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${current_release}" "${target_real}" >> "${DEPLOY_LOG}"
log "rollback が完了しました。"
