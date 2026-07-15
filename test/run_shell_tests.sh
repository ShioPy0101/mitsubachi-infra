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
run_expect_success "install --help" bash "${ROOT}/scripts/install_local.sh" --help

run_expect_failure "configure rejects 0.0.0.0/0" bash "${ROOT}/scripts/configure_local_network.sh" --lan-cidr 0.0.0.0/0 --server-ip 192.168.1.50 --dry-run
run_expect_failure "configure rejects public server IP" bash "${ROOT}/scripts/configure_local_network.sh" --lan-cidr 192.168.1.0/24 --server-ip 8.8.8.8 --dry-run
run_expect_failure "configure rejects IP outside CIDR" bash "${ROOT}/scripts/configure_local_network.sh" --lan-cidr 192.168.2.0/24 --server-ip 192.168.1.50 --dry-run
run_expect_failure "rollback rejects traversal" bash "${ROOT}/scripts/rollback_api.sh" ../bad --skip-restart
run_expect_failure "deploy rejects invalid keep releases" bash "${ROOT}/scripts/deploy_api.sh" --keep-releases 0 --skip-restart --skip-migrate
run_expect_failure "backup storage rejects invalid argument" bash "${ROOT}/scripts/backup_storage.sh" --unknown
run_expect_failure "install rejects interactive without TTY" bash "${ROOT}/scripts/install_local.sh" --interactive --dry-run
run_expect_failure "install rejects interactive and non-interactive together" bash "${ROOT}/scripts/install_local.sh" --interactive --non-interactive --dry-run
run_expect_failure "install rejects invalid bool" bash "${ROOT}/scripts/install_local.sh" --enable-ufw maybe --dry-run
if rg -n 'require_root' "${ROOT}/scripts/install_local.sh" >/dev/null 2>&1; then
  fail "install_local must not require root for whole script"
fi
grep -F "if [[ \"\${EUID}\" -eq 0 ]]" "${ROOT}/scripts/install_local.sh" >/dev/null || fail "install root execution guard"
if rg -n 'sudo +(ruby|bundle|gem)|sudo -u .* +(ruby|bundle|gem)' "${ROOT}/scripts/install_local.sh" >/dev/null 2>&1; then
  fail "install_local must not run ruby/bundle/gem with sudo directly"
fi
grep -F "env HOME=\"\${home}\"" "${ROOT}/scripts/install_local.sh" >/dev/null || fail "install deploy HOME is explicit"
grep -F "RBENV_ROOT=\"\${home}/.rbenv\"" "${ROOT}/scripts/install_local.sh" >/dev/null || fail "install deploy RBENV_ROOT is explicit"
grep -F "PATH=\"\${home}/.rbenv/bin:\${home}/.rbenv/shims:/usr/local/bin:/usr/bin:/bin\"" "${ROOT}/scripts/install_local.sh" >/dev/null || fail "install deploy PATH is explicit"
# shellcheck disable=SC2016
grep -F 'bash -c '\''set -Eeuo pipefail; cd "$HOME"; "$@"'\'' bash "$@"' "${ROOT}/scripts/install_local.sh" >/dev/null || fail "install deploy execution changes to deploy HOME"
# shellcheck disable=SC2016
grep -F 'bash -c '\''set -Eeuo pipefail; cd "$HOME"; "$@"'\'' bash "$@"' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap deploy execution changes to deploy HOME"
# shellcheck disable=SC2016
grep -F 'run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" install "${RUBY_VERSION}"' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap ruby install runs through deploy HOME wrapper"
# shellcheck disable=SC2016
grep -F 'ruby_is_installed "${RUBY_VERSION}"' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap checks real Ruby before build"
# shellcheck disable=SC2016
grep -F 'Ruby ${RUBY_VERSION} は deploy ユーザーの rbenv にインストール済みです。ビルドをスキップします。' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap logs Ruby build skip"
# shellcheck disable=SC2016
grep -F 'gem install bundler --version "${BUNDLER_VERSION}" --no-document' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap installs requested Bundler version idempotently"
# shellcheck disable=SC2016
grep -F 'Bundler ${BUNDLER_VERSION} はインストール済みです。install をスキップします。' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap logs Bundler version skip"
if rg -n 'sudo -u deploy +(git|/home/deploy|env RBENV_ROOT)|sudo -u deploy git|sudo -u deploy /home/deploy' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null 2>&1; then
  fail "bootstrap must not run deploy git/rbenv commands directly from caller cwd"
fi
if rg -n '(chmod|chown|setfacl).*home/sio' "${ROOT}/scripts" >/dev/null 2>&1; then
  fail "scripts must not loosen or take ownership of invoking user's home directory"
fi
grep -F 'check_repository_access()' "${ROOT}/scripts/install_local.sh" >/dev/null || fail "install has invoking-user repository access check"
grep -F "git ls-remote \"\${repository}\" HEAD" "${ROOT}/scripts/install_local.sh" >/dev/null || fail "install repository check uses git without sudo"
if rg -n 'bootstrap_args=\(--app-repo|bootstrap_args\+=\(--app-repo' "${ROOT}/scripts/install_local.sh" >/dev/null 2>&1; then
  fail "install must not pass SSH app repo to root bootstrap"
fi
grep -F '既定 version で続行します' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap optional discovery continues on failure"
# shellcheck disable=SC2016
grep -F 'NGINX_BACKUP_DIR="${NGINX_BACKUP_DIR:-/etc/nginx/backups}"' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap nginx backups are outside sites-enabled"
# shellcheck disable=SC2016
grep -F 'move_misplaced_enabled_backups "${timestamp}"' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap moves old sites-enabled bak files"
# shellcheck disable=SC2016
grep -F 'restore_nginx_path "${previous_available_backup}" "${available_path}" "${keep_available_on_rollback}"' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap restores available config on nginx test failure"
# shellcheck disable=SC2016
grep -F 'restore_nginx_path "${previous_enabled_backup}" "${enabled_path}" "${keep_enabled_on_rollback}"' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap restores enabled config on nginx test failure"
# shellcheck disable=SC2016
grep -F 'restore_nginx_path "${previous_default_backup}" "${default_path}" false' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap restores default site on nginx test failure"
grep -F 'if ! nginx -t; then' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null || fail "bootstrap tests nginx before reload"
nginx_test_line="$(rg -n 'if ! nginx -t; then' "${ROOT}/scripts/bootstrap_ubuntu.sh" | cut -d: -f1 | tail -n1)"
reload_line="$(rg -n 'systemctl reload nginx' "${ROOT}/scripts/bootstrap_ubuntu.sh" | cut -d: -f1 | tail -n1)"
[[ -n "${nginx_test_line}" && -n "${reload_line}" ]] || fail "bootstrap nginx test/reload markers exist"
(( nginx_test_line < reload_line )) || fail "bootstrap reloads nginx only after nginx -t"
if rg -n 'backup_if_exists /etc/nginx/sites-enabled|sites-enabled/.+\\.bak' "${ROOT}/scripts/bootstrap_ubuntu.sh" >/dev/null 2>&1; then
  fail "bootstrap must not leave nginx backups in sites-enabled"
fi
ensure_line="$(rg -n '^ensure_deploy_account$' "${ROOT}/scripts/install_local.sh" | cut -d: -f1 | tail -n1)"
env_line="$(rg -n '^install_rails_env_file$' "${ROOT}/scripts/install_local.sh" | cut -d: -f1 | tail -n1)"
bootstrap_line="$(rg -n 'sudo_cmd "\$\{SCRIPT_DIR\}/bootstrap_ubuntu.sh"' "${ROOT}/scripts/install_local.sh" | cut -d: -f1 | tail -n1)"
[[ -n "${ensure_line}" && -n "${env_line}" && -n "${bootstrap_line}" ]] || fail "install phase order markers exist"
(( ensure_line < env_line && env_line < bootstrap_line )) || fail "install phase order must be account, rails.env, bootstrap"
pass "install sudo/user boundary static checks"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf -- "${tmpdir}" /tmp/mitsubachi-test.out /tmp/mitsubachi-test.err
}
trap cleanup EXIT

install_config="${tmpdir}/local.env"
install_config_empty="${tmpdir}/empty-local.env"
install_config_without_network="${tmpdir}/local-without-network.env"
install_rails_env="${tmpdir}/rails.env"
install_rails_env_min="${tmpdir}/rails-min.env"
install_rails_env_explicit="${tmpdir}/rails-explicit.env"
cat > "${install_config}" <<'CONFIG'
SERVER_IP=192.168.1.50
LAN_CIDR=192.168.1.0/24
RAILS_REPO_URL=git@github.com:ShioPy0101/mitsubachi-ruby.git
RAILS_REF=main
DEPLOY_USER=deploy
DEPLOY_GROUP=deploy
POSTGRES_ROLE=mitsubachi
POSTGRES_DATABASE=mitsubachi_production
KEEP_RELEASES=5
ENABLE_UFW=true
ALLOW_SSH=true
REMOVE_NGINX_DEFAULT_SITE=false
CONFIG
chmod 0600 "${install_config}"
touch "${install_config_empty}"
chmod 0600 "${install_config_empty}"
cat > "${install_config_without_network}" <<'CONFIG'
RAILS_REPO_URL=git@github.com:ShioPy0101/mitsubachi-ruby.git
RAILS_REF=main
DEPLOY_USER=deploy
DEPLOY_GROUP=deploy
POSTGRES_ROLE=mitsubachi
POSTGRES_DATABASE=mitsubachi_production
KEEP_RELEASES=5
ENABLE_UFW=true
ALLOW_SSH=true
REMOVE_NGINX_DEFAULT_SITE=false
CONFIG
chmod 0600 "${install_config_without_network}"
{
  printf '%s=%s\n' RAILS_ENV production
  printf '%s=%s\n' RAILS_MASTER_KEY test-master-key-placeholder
  printf '%s=%s\n' SECRET_KEY_BASE test-secret-key-base-placeholder
  printf '%s=%s\n' DATABASE_URL postgresql://mitsubachi:test-password-placeholder@127.0.0.1:5432/mitsubachi_production
  printf '%s=%s\n' FILE_STORAGE_ROOT /mnt/external-hdd/mitsubachi/files
  printf '%s=%s\n' MAX_UPLOAD_SIZE_BYTES 10737418240
  printf '%s=%s\n' APP_HOST 192.168.1.50
  printf '%s=%s\n' FRONTEND_ORIGIN http://192.168.1.50
  printf '%s=%s\n' FRONTEND_URL http://192.168.1.50
  printf '%s=%s\n' SESSION_COOKIE_SECURE false
} > "${install_rails_env}"
chmod 0600 "${install_rails_env}"
{
  printf '%s=%s\n' RAILS_MASTER_KEY test-master-key-placeholder
  printf '%s=%s\n' SECRET_KEY_BASE test-secret-key-base-placeholder
  printf '%s=%s\n' DATABASE_URL postgresql://mitsubachi:test-password-placeholder@127.0.0.1:5432/mitsubachi_production
  printf '%s=%s\n' FILE_STORAGE_ROOT /mnt/external-hdd/mitsubachi/files
  printf '%s=%s\n' MAX_UPLOAD_SIZE_BYTES 10737418240
  printf '%s=%s\n' SESSION_COOKIE_SECURE false
} > "${install_rails_env_min}"
chmod 0600 "${install_rails_env_min}"
{
  printf '%s=%s\n' RAILS_MASTER_KEY test-master-key-placeholder
  printf '%s=%s\n' SECRET_KEY_BASE test-secret-key-base-placeholder
  printf '%s=%s\n' DATABASE_URL postgresql://mitsubachi:test-password-placeholder@127.0.0.1:5432/mitsubachi_production
  printf '%s=%s\n' FILE_STORAGE_ROOT /mnt/external-hdd/mitsubachi/files
  printf '%s=%s\n' MAX_UPLOAD_SIZE_BYTES 10737418240
  printf '%s=%s\n' APP_HOST 192.168.1.60
  printf '%s=%s\n' FRONTEND_ORIGIN http://192.168.1.60
  printf '%s=%s\n' FRONTEND_URL http://192.168.1.60
  printf '%s=%s\n' SESSION_COOKIE_SECURE false
} > "${install_rails_env_explicit}"
chmod 0600 "${install_rails_env_explicit}"
touch "${tmpdir}/empty-rails.env"
chmod 0600 "${tmpdir}/empty-rails.env"

run_expect_success "install dry-run non-interactive" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config}" \
  --rails-env-file "${install_rails_env}" \
  --non-interactive \
  --yes \
  --dry-run
grep -F '[DRY-RUN] create system group if missing: deploy' /tmp/mitsubachi-test.err >/dev/null || fail "dry-run shows deploy group creation"
grep -F '[DRY-RUN] create system user if missing: deploy' /tmp/mitsubachi-test.err >/dev/null || fail "dry-run shows deploy user creation"
grep -F '[DRY-RUN] create directory: /etc/mitsubachi owner=root group=deploy mode=0750' /tmp/mitsubachi-test.err >/dev/null || fail "dry-run shows etc directory after account"
if rg -n 'test-master-key-placeholder|test-secret-key-base-placeholder|test-password-placeholder' /tmp/mitsubachi-test.out /tmp/mitsubachi-test.err >/dev/null 2>&1; then
  fail "install dry-run leaked secret"
fi
pass "install dry-run redacts secrets"

run_expect_failure "install rejects unsupported non-default deploy account" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config_empty}" \
  --rails-env-file "${install_rails_env_min}" \
  --deploy-user appuser \
  --deploy-group appgroup \
  --non-interactive \
  --yes \
  --dry-run
rg -n 'DEPLOY_USER=deploy|DEPLOY_GROUP=deploy' /tmp/mitsubachi-test.err >/dev/null || fail "non-default deploy account has explicit error"
pass "install non-default deploy account fails explicitly"

run_expect_success "install defaults all host values from default SERVER_IP" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config_empty}" \
  --rails-env-file "${install_rails_env_min}" \
  --non-interactive \
  --yes \
  --dry-run
grep -F 'Server IP:          192.168.1.50' /tmp/mitsubachi-test.out >/dev/null || fail "default SERVER_IP"
grep -F 'App host:           192.168.1.50' /tmp/mitsubachi-test.out >/dev/null || fail "APP_HOST defaults from default SERVER_IP"
grep -F 'Frontend origin:    http://192.168.1.50' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_ORIGIN defaults from default SERVER_IP"
grep -F 'Frontend URL:       http://192.168.1.50' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_URL defaults from default SERVER_IP"
pass "install default-only derived host values"

run_expect_success "install defaults APP_HOST and frontend URLs" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config}" \
  --rails-env-file "${install_rails_env_min}" \
  --non-interactive \
  --yes \
  --dry-run
grep -F 'App host:           192.168.1.50' /tmp/mitsubachi-test.out >/dev/null || fail "APP_HOST defaults to SERVER_IP"
grep -F 'Frontend origin:    http://192.168.1.50' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_ORIGIN defaults to SERVER_IP"
grep -F 'Frontend URL:       http://192.168.1.50' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_URL defaults to SERVER_IP"
pass "install default host values"

run_expect_success "install CLI SERVER_IP updates derived host values" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config_empty}" \
  --rails-env-file "${install_rails_env_min}" \
  --server-ip 192.168.10.151 \
  --lan-cidr 192.168.10.0/24 \
  --non-interactive \
  --yes \
  --dry-run
grep -F 'Server IP:          192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "CLI SERVER_IP shown"
grep -F 'App host:           192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "APP_HOST derives from CLI SERVER_IP"
grep -F 'Frontend origin:    http://192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_ORIGIN derives from CLI SERVER_IP"
grep -F 'Frontend URL:       http://192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_URL derives from CLI SERVER_IP"
pass "install CLI server derived host values"

run_expect_success "install accepts HTTPS Rails repository URL" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config_empty}" \
  --rails-env-file "${install_rails_env_min}" \
  --rails-repo-url https://github.com/ShioPy0101/mitsubachi-ruby.git \
  --non-interactive \
  --yes \
  --dry-run
grep -F 'Rails repository:   https://github.com/ShioPy0101/mitsubachi-ruby.git' /tmp/mitsubachi-test.out >/dev/null || fail "HTTPS Rails repo shown"
pass "install HTTPS git URL"

run_expect_success "install preserves explicit APP_HOST and frontend URLs" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config}" \
  --rails-env-file "${install_rails_env_explicit}" \
  --non-interactive \
  --yes \
  --dry-run
grep -F 'App host:           192.168.1.60' /tmp/mitsubachi-test.out >/dev/null || fail "APP_HOST explicit value preserved"
grep -F 'Frontend origin:    http://192.168.1.60' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_ORIGIN explicit value preserved"
grep -F 'Frontend URL:       http://192.168.1.60' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_URL explicit value preserved"
pass "install explicit host values"

if command -v script >/dev/null 2>&1; then
  run_expect_success "install interactive TTY dry-run" script -qfec "bash '${ROOT}/scripts/install_local.sh' --config '${install_config}' --rails-env-file '${install_rails_env_min}' --interactive --yes --dry-run" /dev/null
  if rg -n 'unbound variable|未割り当ての変数' /tmp/mitsubachi-test.out /tmp/mitsubachi-test.err >/dev/null 2>&1; then
    fail "install interactive TTY dry-run used unbound variable error"
  fi
  pass "install interactive path avoids unbound variables"

  printf '192.168.10.151\n192.168.10.0/24\n' > "${tmpdir}/interactive-network-input"
  run_expect_success "install interactive SERVER_IP updates derived host values" bash -c "script -qfec \"bash '${ROOT}/scripts/install_local.sh' --config '${install_config_without_network}' --rails-env-file '${install_rails_env_min}' --interactive --yes --dry-run\" /dev/null < '${tmpdir}/interactive-network-input'"
  grep -F 'Server IP:          192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "interactive SERVER_IP shown"
  grep -F 'App host:           192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "APP_HOST derives from interactive SERVER_IP"
  grep -F 'Frontend origin:    http://192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_ORIGIN derives from interactive SERVER_IP"
  grep -F 'Frontend URL:       http://192.168.10.151' /tmp/mitsubachi-test.out >/dev/null || fail "FRONTEND_URL derives from interactive SERVER_IP"
  pass "install interactive server derived host values"
fi

run_expect_failure "install non-interactive missing secrets fails" bash "${ROOT}/scripts/install_local.sh" \
  --config "${install_config}" \
  --rails-env-file "${tmpdir}/empty-rails.env" \
  --non-interactive \
  --yes \
  --dry-run
if rg -n 'unbound variable|未割り当ての変数' /tmp/mitsubachi-test.err >/dev/null 2>&1; then
  fail "install missing required value used unbound variable error"
fi
rg -n 'RAILS_MASTER_KEY が不足しています' /tmp/mitsubachi-test.err >/dev/null || fail "install missing required value lacks explicit error"
pass "install missing required value reports explicit error"

if rg -n 'RAILS_MASTER_KEY|SECRET_KEY_BASE|DATABASE_URL|RESEND_API_KEY' "${install_config}" >/dev/null 2>&1; then
  fail "config/local.env contains secret keys"
fi
pass "non-secret config excludes secrets"

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
grep -F 'config/local.env' "${ROOT}/.gitignore" >/dev/null || fail "gitignore local config"
grep -F 'env/rails.env' "${ROOT}/.gitignore" >/dev/null || fail "gitignore local rails env"
grep -F 'alias /mnt/external-hdd/mitsubachi/files/drive_items/;' "${ROOT}/nginx/mitsubachi-local.conf" >/dev/null || fail "nginx alias"
grep -F 'location /internal/storage/drive_items/' "${ROOT}/nginx/mitsubachi-local.conf" >/dev/null || fail "nginx internal URI"
grep -F "POSTGRES_BACKUP_DIR=\"\${POSTGRES_BACKUP_DIR:-\${MITSUBACHI_HDD_ROOT}/backups/postgres}\"" "${ROOT}/scripts/lib/common.sh" >/dev/null || fail "postgres backup path"
grep -F "STORAGE_BACKUP_DIR=\"\${STORAGE_BACKUP_DIR:-\${MITSUBACHI_HDD_ROOT}/backups/storage}\"" "${ROOT}/scripts/lib/common.sh" >/dev/null || fail "storage backup path"
if rg -n '/srv/mitsubachi|/var/www/mitsubachi-ruby' "${ROOT}/env" "${ROOT}/nginx" "${ROOT}/systemd" "${ROOT}/scripts" >/tmp/mitsubachi-test.out 2>/tmp/mitsubachi-test.err; then
  fail "forbidden runtime path in executable configuration"
fi
pass "static path consistency"

printf 'All shell tests passed.\n'
