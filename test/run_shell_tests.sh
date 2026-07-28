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

run_expect_success "ruby cli help" ruby "${ROOT}/bin/mitsubachi-infra" help
run_expect_success "ruby exe cli help" ruby "${ROOT}/exe/mitsubachi-infra" help
run_expect_failure "install bootstrap requires root" bash "${ROOT}/scripts/install_local.sh" --dry-run
grep -F 'root 権限で実行してください' /tmp/mitsubachi-test.err >/dev/null || fail "bootstrap root error is clear"

run_expect_success "ruby unit tests" ruby "${ROOT}/test/test_mitsubachi_infra.rb"

run_expect_success "cli status dry-run json" ruby "${ROOT}/bin/mitsubachi-infra" --config "${ROOT}/test/fixtures/config.lan.yml" --dry-run status --json
grep -F '"deployment_mode": "lan"' /tmp/mitsubachi-test.out >/dev/null || fail "status json contains deployment mode"

run_expect_failure "cli deploy backend dry-run requires root" ruby "${ROOT}/bin/mitsubachi-infra" --config "${ROOT}/test/fixtures/config.lan.yml" --dry-run deploy backend --ref main
grep -F 'deploy must be run as root' /tmp/mitsubachi-test.err >/dev/null || fail "deploy root error is clear"

run_expect_failure "cli rollback dry-run requires root" ruby "${ROOT}/bin/mitsubachi-infra" --config "${ROOT}/test/fixtures/config.lan.yml" --dry-run rollback backend
grep -F 'rollback must be run as root' /tmp/mitsubachi-test.err >/dev/null || fail "rollback root error is clear"

run_expect_failure "cli https enable dry-run staging requires root" ruby "${ROOT}/bin/mitsubachi-infra" --config "${ROOT}/test/fixtures/config.public.yml" --dry-run https enable --staging
grep -F 'https must be run as root' /tmp/mitsubachi-test.err >/dev/null || fail "https root error is clear"

run_expect_success "legacy scripts still expose help" bash "${ROOT}/scripts/deploy_api.sh" --help
run_expect_success "rollback legacy help" bash "${ROOT}/scripts/rollback_api.sh" --help
run_expect_success "backup postgres legacy help" bash "${ROOT}/scripts/backup_postgres.sh" --help

grep -F 'EnvironmentFile=<%= @config.fetch("paths").fetch("rails_env") %>' "${ROOT}/templates/systemd/mitsubachi-api.service.erb" >/dev/null || fail "systemd template reads rails env"
grep -F 'bundle exec bin/jobs' "${ROOT}/templates/systemd/mitsubachi-jobs.service.erb" >/dev/null || fail "worker systemd template runs bin/jobs"
grep -F 'proxy_pass http://127.0.0.1:<%= config.fetch("ports").fetch("rails") %>;' "${ROOT}/templates/nginx/public_https.conf.erb" >/dev/null || fail "Nginx proxies API to localhost Rails"
grep -F 'error_page 404 =200 /index.html;' "${ROOT}/templates/nginx/public_https.conf.erb" >/dev/null || fail "Nginx public template maps frontend deep-link 404 to SPA index"
grep -F 'try_files $uri $uri/ =404;' "${ROOT}/templates/nginx/public_https.conf.erb" >/dev/null || fail "Nginx public template preserves explicit file lookup"
# shellcheck disable=SC2016
grep -F 'error_page 404 =200 /index.html;' "${ROOT}/templates/nginx/lan.conf.erb" >/dev/null || fail "nginx lan template maps frontend deep-link 404 to SPA index"
grep -F 'location /api/' "${ROOT}/templates/nginx/lan.conf.erb" >/dev/null || fail "nginx lan keeps api proxy"
grep -F 'certbot' "${ROOT}/lib/mitsubachi_infra/certbot.rb" >/dev/null || fail "certbot integration exists"
grep -F 'Open3.capture3' "${ROOT}/lib/mitsubachi_infra/command_runner.rb" >/dev/null || fail "CommandRunner uses Open3"

if rg -n 'StrictHostKeyChecking=no|ssh .*@|scp ' "${ROOT}/lib" >/tmp/mitsubachi-test.out 2>/tmp/mitsubachi-test.err; then
  fail "production CLI must not automate SSH from development host"
fi

if rg -n 'system\\("|`git |git clone #|certbot .*#\\{' "${ROOT}/lib" >/tmp/mitsubachi-test.out 2>/tmp/mitsubachi-test.err; then
  fail "ruby code must not assemble shell commands"
fi

if rg -n 'RAILS_MASTER_KEY=[A-Za-z0-9]|SECRET_KEY_BASE=[A-Za-z0-9]|RESEND_API_KEY=[A-Za-z0-9]' "${ROOT}" --glob '!test/**' >/tmp/mitsubachi-test.out 2>/tmp/mitsubachi-test.err; then
  fail "tracked files contain obvious secrets"
fi

printf 'All tests passed.\n'
