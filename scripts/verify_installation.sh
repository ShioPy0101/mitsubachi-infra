#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
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
  [[ "${VERSION_ID:-}" == "24.04" ]] && pass "Ubuntu 24.04" || warn "Ubuntu version は ${PRETTY_NAME:-unknown} です。想定は 24.04 LTS です。"
else
  fail "/etc/os-release readable"
fi
if [[ -n "${SERVER_IP}" ]]; then
  private_ipv4 "${SERVER_IP}" && pass "server IP は private IPv4" || fail "server IP は private IPv4"
fi
if [[ -n "${LAN_CIDR}" && -n "${SERVER_IP}" ]]; then
  cidr_contains_ipv4 "${LAN_CIDR}" "${SERVER_IP}" && pass "server IP は LAN CIDR 内" || fail "server IP は LAN CIDR 内"
fi

set_stage "storage"
check "外付け HDD が mount されている" mountpoint -q "${EXTERNAL_HDD}"
check "storage directory が存在する" test -d "${DRIVE_ITEMS_ROOT}"
check "外付け HDD が read/write 可能" require_filesystem_rw "${EXTERNAL_HDD}"
df -h -- "${EXTERNAL_HDD}" || true
id deploy >/dev/null 2>&1 && pass "deploy user が存在する" || fail "deploy user が存在する"
id www-data >/dev/null 2>&1 && pass "www-data user が存在する" || fail "www-data user が存在する"
sudo -n -u deploy test -w "${DRIVE_ITEMS_ROOT}" >/dev/null 2>&1 && pass "deploy は storage に書き込める" || warn "deploy 書き込み確認を実行できない、または失敗しました。sudo で実行してください。"
sudo -n -u www-data test -r "${DRIVE_ITEMS_ROOT}" >/dev/null 2>&1 && pass "www-data は storage を読める" || warn "www-data 読み取り確認を実行できない、または失敗しました。sudo で実行してください。"
sudo -n -u www-data test ! -w "${DRIVE_ITEMS_ROOT}" >/dev/null 2>&1 && pass "www-data は storage に書き込めない" || warn "www-data 書き込み不可確認を実行できない、または失敗しました。"

set_stage "env file"
if [[ -f "${RAILS_ENV_FILE}" ]]; then
  pass "rails env file が存在する"
  owner="$(stat -c '%U:%G %a' "${RAILS_ENV_FILE}")"
  [[ "${owner}" == "root:deploy 640" ]] && pass "rails env owner/group/mode は root:deploy 640" || warn "rails env owner/group/mode は ${owner} です。推奨は root:deploy 640 です。"
else
  fail "rails env file が存在する"
fi

set_stage "release and systemd"
[[ -L "${CURRENT_LINK}" ]] && pass "current symlink が存在する" || warn "初回 deploy 前のため current symlink がありません。"
[[ -f /etc/systemd/system/mitsubachi-api.service ]] && pass "systemd unit が install 済み" || warn "systemd unit が未 install です。"
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-enabled mitsubachi-api.service >/dev/null 2>&1 && pass "mitsubachi-api は enable 済み" || warn "mitsubachi-api は enable されていません。"
  systemctl is-active mitsubachi-api.service >/dev/null 2>&1 && pass "mitsubachi-api は active" || warn "mitsubachi-api は active ではありません。"
fi

set_stage "ports"
if command -v ss >/dev/null 2>&1; then
  ss -ltnp | grep -E '127\.0\.0\.1:3001|localhost:3001' >/dev/null && pass "Puma は localhost:3001 で listen" || warn "Puma localhost:3001 listener が見つかりません。"
  ss -ltnp | grep -E '(^|[[:space:]])0\.0\.0\.0:3001|(^|[[:space:]])\[::\]:3001' >/dev/null && fail "TCP 3001 が外部 bind されています" || pass "TCP 3001 は外部 bind されていない"
  ss -ltnp | grep -E '(^|[[:space:]])0\.0\.0\.0:5432|(^|[[:space:]])\[::\]:5432' >/dev/null && fail "PostgreSQL 5432 が外部 bind されています" || pass "PostgreSQL 5432 は外部 bind されていない"
else
  warn "ss が見つからないため port check を skip しました。"
fi

set_stage "nginx"
if command -v nginx >/dev/null 2>&1; then
  nginx -t && pass "nginx configuration test" || fail "nginx configuration test"
  [[ -L /etc/nginx/sites-enabled/mitsubachi-local.conf || -f /etc/nginx/sites-enabled/mitsubachi-local.conf ]] && pass "mitsubachi nginx site が enabled" || warn "mitsubachi nginx site が enabled ではありません。"
fi

set_stage "health"
curl -fsS -o /dev/null "${HEALTH_BASE}/api/health/live" && pass "health live" || warn "health live に到達できません。"
curl -fsS -o /dev/null "${HEALTH_BASE}/api/health/ready" && pass "health ready" || warn "health ready に到達できません。"
code="$(curl -sS -o /dev/null -w '%{http_code}' "${HEALTH_BASE}/internal/storage/drive_items/does-not-exist" || true)"
case "${code}" in
  403|404) pass "internal URI 直接アクセスは拒否されています (${code})" ;;
  *) warn "internal URI 直接アクセスの応答が ${code} です。Nginx 経由では 403 または 404 を想定します。" ;;
esac

set_stage "consistency"
if [[ -f "${REPO_ROOT}/nginx/mitsubachi-local.conf" ]]; then
  grep -F 'location /internal/storage/drive_items/' "${REPO_ROOT}/nginx/mitsubachi-local.conf" >/dev/null && pass "Nginx internal URI は Rails 契約と一致" || fail "Nginx internal URI は Rails 契約と一致"
  grep -F 'alias /mnt/external-hdd/mitsubachi/files/drive_items/;' "${REPO_ROOT}/nginx/mitsubachi-local.conf" >/dev/null && pass "Nginx alias は FILE_STORAGE_ROOT と一致" || fail "Nginx alias は FILE_STORAGE_ROOT と一致"
fi
if [[ -f "${REPO_ROOT}/systemd/mitsubachi-api.service" ]]; then
  grep -F 'WorkingDirectory=/var/www/mitsubachi/current' "${REPO_ROOT}/systemd/mitsubachi-api.service" >/dev/null && pass "systemd WorkingDirectory は current symlink と一致" || fail "systemd WorkingDirectory は current symlink と一致"
fi
if command -v ufw >/dev/null 2>&1; then
  ufw status verbose || true
fi

if (( FAILURES > 0 )); then
  die "検証に失敗しました。失敗件数=${FAILURES}"
fi
log "インストール検証が完了しました。"
