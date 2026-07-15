#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'OK   %s\n' "$*"
}

run_expect_success() {
  local label="$1"
  shift
  "$@" >/tmp/mitsubachi-test.out 2>/tmp/mitsubachi-test.err || {
    cat /tmp/mitsubachi-test.err >&2 || true
    fail "${label}"
  }
  pass "${label}"
}

run_expect_failure() {
  local label="$1"
  shift
  if "$@" >/tmp/mitsubachi-test.out 2>/tmp/mitsubachi-test.err; then
    cat /tmp/mitsubachi-test.out >&2 || true
    fail "${label}"
  fi
  pass "${label}"
}

run_expect_success "bootstrap --help" bash "${ROOT}/scripts/bootstrap_ubuntu.sh" --help
run_expect_success "configure --help" bash "${ROOT}/scripts/configure_local_network.sh" --help
run_expect_success "deploy --help" bash "${ROOT}/scripts/deploy_api.sh" --help
run_expect_success "rollback --help" bash "${ROOT}/scripts/rollback_api.sh" --help
run_expect_success "backup postgres --help" bash "${ROOT}/scripts/backup_postgres.sh" --help
run_expect_success "backup storage --help" bash "${ROOT}/scripts/backup_storage.sh" --help
run_expect_success "verify --help" bash "${ROOT}/scripts/verify_installation.sh" --help

run_expect_failure "configure rejects 0.0.0.0/0" bash "${ROOT}/scripts/configure_local_network.sh" --lan-cidr 0.0.0.0/0 --server-ip 192.168.1.50 --dry-run
run_expect_failure "configure rejects public server IP" bash "${ROOT}/scripts/configure_local_network.sh" --lan-cidr 192.168.1.0/24 --server-ip 8.8.8.8 --dry-run
run_expect_failure "configure rejects IP outside CIDR" bash "${ROOT}/scripts/configure_local_network.sh" --lan-cidr 192.168.2.0/24 --server-ip 192.168.1.50 --dry-run
run_expect_failure "rollback rejects traversal" bash "${ROOT}/scripts/rollback_api.sh" ../bad --skip-restart
run_expect_failure "deploy rejects invalid keep releases" bash "${ROOT}/scripts/deploy_api.sh" --keep-releases 0 --skip-restart --skip-migrate
run_expect_failure "backup storage rejects invalid argument" bash "${ROOT}/scripts/backup_storage.sh" --unknown

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf -- "${tmpdir}" /tmp/mitsubachi-test.out /tmp/mitsubachi-test.err
}
trap cleanup EXIT

source "${ROOT}/scripts/lib/common.sh"
mkdir -p "${tmpdir}/releases/a" "${tmpdir}/releases/b"
atomic_symlink_switch "${tmpdir}/releases/a" "${tmpdir}/current"
[[ "$(readlink -f -- "${tmpdir}/current")" == "${tmpdir}/releases/a" ]] || fail "atomic symlink initial"
atomic_symlink_switch "${tmpdir}/releases/b" "${tmpdir}/current"
[[ "$(readlink -f -- "${tmpdir}/current")" == "${tmpdir}/releases/b" ]] || fail "atomic symlink switch"
pass "atomic symlink switch"

validate_safe_basename "20260716T000000Z-abcdef123456"
if ( validate_safe_basename "../bad" ) 2>/dev/null; then
  fail "safe basename rejects traversal"
fi
pass "safe basename rejects traversal"

cidr_contains_ipv4 "192.168.1.0/24" "192.168.1.50" || fail "CIDR contains private IP"
if cidr_contains_ipv4 "192.168.2.0/24" "192.168.1.50"; then
  fail "CIDR rejects outside IP"
fi
pass "CIDR validation"

grep -F 'WorkingDirectory=/var/www/mitsubachi/current' "${ROOT}/systemd/mitsubachi-api.service" >/dev/null || fail "systemd WorkingDirectory"
grep -F 'RequiresMountsFor=/mnt/external-hdd/mitsubachi/files' "${ROOT}/systemd/mitsubachi-api.service" >/dev/null || fail "systemd RequiresMountsFor"
grep -F 'FILE_STORAGE_ROOT=/mnt/external-hdd/mitsubachi/files' "${ROOT}/env/rails.env.example" >/dev/null || fail "env FILE_STORAGE_ROOT"
grep -F 'BULK_DOWNLOAD_TMP=/mnt/external-hdd/mitsubachi/tmp/bulk_downloads' "${ROOT}/env/rails.env.example" >/dev/null || fail "env BULK_DOWNLOAD_TMP"
grep -F 'alias /mnt/external-hdd/mitsubachi/files/drive_items/;' "${ROOT}/nginx/mitsubachi-local.conf" >/dev/null || fail "nginx alias"
grep -F 'location /internal/storage/drive_items/' "${ROOT}/nginx/mitsubachi-local.conf" >/dev/null || fail "nginx internal URI"
grep -F "POSTGRES_BACKUP_DIR=\"\${POSTGRES_BACKUP_DIR:-\${MITSUBACHI_HDD_ROOT}/backups/postgres}\"" "${ROOT}/scripts/lib/common.sh" >/dev/null || fail "postgres backup path"
grep -F "STORAGE_BACKUP_DIR=\"\${STORAGE_BACKUP_DIR:-\${MITSUBACHI_HDD_ROOT}/backups/storage}\"" "${ROOT}/scripts/lib/common.sh" >/dev/null || fail "storage backup path"
if rg -n '/srv/mitsubachi|/var/www/mitsubachi-ruby' "${ROOT}/env" "${ROOT}/nginx" "${ROOT}/systemd" "${ROOT}/scripts" >/tmp/mitsubachi-test.out 2>/tmp/mitsubachi-test.err; then
  fail "forbidden runtime path in executable configuration"
fi
pass "static path consistency"

printf 'All shell tests passed.\n'
