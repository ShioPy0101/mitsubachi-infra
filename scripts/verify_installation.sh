#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/verify_installation.sh [options]

Options:
  --server-ip IP           Expected private IPv4 address.
  --lan-cidr CIDR          Expected LAN CIDR for UFW checks.
  --health-base URL        Base URL. Default: http://127.0.0.1:3001.
  --help                   Show this help.
USAGE
}

SERVER_IP=""
LAN_CIDR=""
HEALTH_BASE="http://127.0.0.1:3001"

while (($#)); do
  case "$1" in
    --server-ip) SERVER_IP="${2:-}"; shift 2 ;;
    --lan-cidr) LAN_CIDR="${2:-}"; shift 2 ;;
    --health-base) HEALTH_BASE="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command awk grep sed find readlink stat curl

pass() { printf 'OK   %s\n' "$*"; }
warn() { printf '警告 %s\n' "$*"; }
fail() { printf '失敗 %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
check() {
  local label="$1"
  shift
  if "$@"; then pass "${label}"; else fail "${label}"; fi
}

FAILURES=0

set_stage "os and network"
# verify は破壊的変更を一切しない。実サーバーでの設定漏れを早く見つける
# ために、致命的なものは「失敗」、初回 deploy 前に未成立でもあり得るものは
# 「警告」として分ける。secrets は読み取らず、表示もしない。
log "インストール検証を開始します。破壊的変更は行いません。"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${VERSION_ID:-}" == "24.04" ]]; then
    pass "Ubuntu 24.04"
  else
    warn "Ubuntu version は ${PRETTY_NAME:-unknown} です。想定は 24.04 LTS です。"
  fi
else
  fail "/etc/os-release readable"
fi
if [[ -n "${SERVER_IP}" ]]; then
  if private_ipv4 "${SERVER_IP}"; then
    pass "server IP は private IPv4"
  else
    fail "server IP は private IPv4"
  fi
fi
if [[ -n "${LAN_CIDR}" && -n "${SERVER_IP}" ]]; then
  if cidr_contains_ipv4 "${LAN_CIDR}" "${SERVER_IP}"; then
    pass "server IP は LAN CIDR 内"
  else
    fail "server IP は LAN CIDR 内"
  fi
fi

set_stage "storage"
check "外付け HDD が mount されている" mountpoint -q "${EXTERNAL_HDD}"
check "storage directory が存在する" test -d "${DRIVE_ITEMS_ROOT}"
check "外付け HDD が read/write 可能" require_filesystem_rw "${EXTERNAL_HDD}"
df -h -- "${EXTERNAL_HDD}" || true
if id deploy >/dev/null 2>&1; then pass "deploy user が存在する"; else fail "deploy user が存在する"; fi
if id www-data >/dev/null 2>&1; then pass "www-data user が存在する"; else fail "www-data user が存在する"; fi
if sudo -n -u deploy test -w "${DRIVE_ITEMS_ROOT}" >/dev/null 2>&1; then
  pass "deploy は storage に書き込める"
else
  warn "deploy 書き込み確認を実行できない、または失敗しました。sudo で実行してください。"
fi
if sudo -n -u www-data test -r "${DRIVE_ITEMS_ROOT}" >/dev/null 2>&1; then
  pass "www-data は storage を読める"
else
  warn "www-data 読み取り確認を実行できない、または失敗しました。sudo で実行してください。"
fi
if sudo -n -u www-data test ! -w "${DRIVE_ITEMS_ROOT}" >/dev/null 2>&1; then
  pass "www-data は storage に書き込めない"
else
  warn "www-data 書き込み不可確認を実行できない、または失敗しました。"
fi

set_stage "env file"
if [[ -f "${RAILS_ENV_FILE}" ]]; then
  pass "rails env file が存在する"
  owner="$(stat -c '%U:%G %a' "${RAILS_ENV_FILE}")"
  if [[ "${owner}" == "root:deploy 640" ]]; then
    pass "rails env owner/group/mode は root:deploy 640"
  else
    warn "rails env owner/group/mode は ${owner} です。推奨は root:deploy 640 です。"
  fi
else
  fail "rails env file が存在する"
fi
if [[ -f "${RAILS_ENV_FILE}" ]]; then
  if grep -F 'FILE_STORAGE_ROOT=/mnt/external-hdd/mitsubachi/files' "${RAILS_ENV_FILE}" >/dev/null; then
    pass "rails env FILE_STORAGE_ROOT は正式パス"
  else
    warn "rails env FILE_STORAGE_ROOT が正式パスと一致しません。/mnt/external-hdd/mitsubachi/files を確認してください。"
  fi
fi

set_stage "release and systemd"
if [[ -L "${CURRENT_LINK}" ]]; then pass "current symlink が存在する"; else warn "初回 deploy 前のため current symlink がありません。"; fi
if [[ -f /etc/systemd/system/mitsubachi-api.service ]]; then pass "systemd unit が install 済み"; else warn "systemd unit が未 install です。"; fi
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-enabled mitsubachi-api.service >/dev/null 2>&1; then pass "mitsubachi-api は enable 済み"; else warn "mitsubachi-api は enable されていません。"; fi
  if systemctl is-active mitsubachi-api.service >/dev/null 2>&1; then pass "mitsubachi-api は active"; else warn "mitsubachi-api は active ではありません。"; fi
fi

set_stage "ports"
if command -v ss >/dev/null 2>&1; then
  if ss -ltnp | grep -E '127\.0\.0\.1:3001|localhost:3001' >/dev/null; then pass "Puma は localhost:3001 で listen"; else warn "Puma localhost:3001 listener が見つかりません。"; fi
  if ss -ltnp | grep -E '(^|[[:space:]])0\.0\.0\.0:3001|(^|[[:space:]])\[::\]:3001' >/dev/null; then fail "TCP 3001 が外部 bind されています"; else pass "TCP 3001 は外部 bind されていない"; fi
  if ss -ltnp | grep -E '(^|[[:space:]])0\.0\.0\.0:5432|(^|[[:space:]])\[::\]:5432' >/dev/null; then fail "PostgreSQL 5432 が外部 bind されています"; else pass "PostgreSQL 5432 は外部 bind されていない"; fi
else
  warn "ss が見つからないため port check を skip しました。"
fi

set_stage "nginx"
if command -v nginx >/dev/null 2>&1; then
  if nginx -t; then pass "nginx configuration test"; else fail "nginx configuration test"; fi
  if [[ -L /etc/nginx/sites-enabled/mitsubachi-local.conf || -f /etc/nginx/sites-enabled/mitsubachi-local.conf ]]; then pass "mitsubachi nginx site が enabled"; else warn "mitsubachi nginx site が enabled ではありません。"; fi
fi

set_stage "health"
if curl -fsS -o /dev/null "${HEALTH_BASE}/api/health/live"; then pass "health live"; else warn "health live に到達できません。"; fi
if curl -fsS -o /dev/null "${HEALTH_BASE}/api/health/ready"; then pass "health ready"; else warn "health ready に到達できません。"; fi
code="$(curl -sS -o /dev/null -w '%{http_code}' "${HEALTH_BASE}/internal/storage/drive_items/does-not-exist" || true)"
case "${code}" in
  403|404) pass "internal URI 直接アクセスは拒否されています (${code})" ;;
  *) warn "internal URI 直接アクセスの応答が ${code} です。Nginx 経由では 403 または 404 を想定します。" ;;
esac

set_stage "consistency"
if [[ -f "${REPO_ROOT}/nginx/mitsubachi-local.conf" ]]; then
  if grep -F 'location /internal/storage/drive_items/' "${REPO_ROOT}/nginx/mitsubachi-local.conf" >/dev/null; then pass "Nginx internal URI は Rails 契約と一致"; else fail "Nginx internal URI は Rails 契約と一致"; fi
  if grep -F 'alias /mnt/external-hdd/mitsubachi/files/drive_items/;' "${REPO_ROOT}/nginx/mitsubachi-local.conf" >/dev/null; then pass "Nginx alias は FILE_STORAGE_ROOT と一致"; else fail "Nginx alias は FILE_STORAGE_ROOT と一致"; fi
fi
if [[ -f "${REPO_ROOT}/systemd/mitsubachi-api.service" ]]; then
  if grep -F 'WorkingDirectory=/var/www/mitsubachi/current' "${REPO_ROOT}/systemd/mitsubachi-api.service" >/dev/null; then pass "systemd WorkingDirectory は current symlink と一致"; else fail "systemd WorkingDirectory は current symlink と一致"; fi
  if grep -F 'RequiresMountsFor=/mnt/external-hdd/mitsubachi/files' "${REPO_ROOT}/systemd/mitsubachi-api.service" >/dev/null; then pass "systemd RequiresMountsFor は外付け HDD files"; else fail "systemd RequiresMountsFor は外付け HDD files"; fi
fi
if grep -F "CURRENT_LINK=\"\${CURRENT_LINK:-\${APP_ROOT}/current}\"" "${REPO_ROOT}/scripts/lib/common.sh" >/dev/null; then
  pass "deploy/rollback 共通 current path は /var/www/mitsubachi/current"
else
  fail "deploy/rollback 共通 current path は /var/www/mitsubachi/current"
fi
if grep -F "POSTGRES_BACKUP_DIR=\"\${POSTGRES_BACKUP_DIR:-\${MITSUBACHI_HDD_ROOT}/backups/postgres}\"" "${REPO_ROOT}/scripts/lib/common.sh" >/dev/null; then
  pass "PostgreSQL backup path は正式パス"
else
  fail "PostgreSQL backup path は正式パス"
fi
if grep -F "STORAGE_BACKUP_DIR=\"\${STORAGE_BACKUP_DIR:-\${MITSUBACHI_HDD_ROOT}/backups/storage}\"" "${REPO_ROOT}/scripts/lib/common.sh" >/dev/null; then
  pass "storage backup path は正式パス"
else
  fail "storage backup path は正式パス"
fi
if command -v ufw >/dev/null 2>&1; then
  ufw status verbose || true
fi

if (( FAILURES > 0 )); then
  die "検証に失敗しました。失敗件数=${FAILURES}"
fi
log "インストール検証が完了しました。"
