#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/deploy_api.sh [options]

Options:
  --repo-url URL          Rails API repository URL.
                          Default: git@github.com:ShioPy0101/mitsubachi-ruby.git
  --ref REF               Git ref to deploy. Default: main.
  --keep-releases N       Number of releases to keep. Default: 5.
  --health-url URL        Ready health URL. Default: http://127.0.0.1:3000/api/health/ready.
  --health-host HOST      Host header for Rails health check.
  --skip-migrate          Do not run rails db:migrate.
  --skip-restart          Do not restart systemd service or run post-restart health check.
  --help                  Show this help.
USAGE
}

RAILS_REPO_URL="git@github.com:ShioPy0101/mitsubachi-ruby.git"
REF="main"
KEEP_RELEASES=5
HEALTH_URL="http://127.0.0.1:3000/api/health/ready"
HEALTH_HOST="${HEALTH_HOST:-}"
SKIP_MIGRATE=false
SKIP_RESTART=false

while (($#)); do
  case "$1" in
    --repo-url) RAILS_REPO_URL="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --keep-releases) KEEP_RELEASES="${2:-}"; shift 2 ;;
    --health-url) HEALTH_URL="${2:-}"; shift 2 ;;
    --health-host) HEALTH_HOST="${2:-}"; shift 2 ;;
    --skip-migrate) SKIP_MIGRATE=true; shift ;;
    --skip-restart) SKIP_RESTART=true; shift ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_not_root
require_command git ruby bundle curl flock awk sed find sort tail xargs
[[ -n "${RAILS_REPO_URL}" ]] || die "--repo-url must not be empty"
[[ -n "${REF}" ]] || die "--ref must not be empty"
if ! [[ "${KEEP_RELEASES}" =~ ^[0-9]+$ ]] || (( KEEP_RELEASES < 1 )); then
  die "--keep-releases must be a positive integer"
fi

with_lock "deploy-api"

set_stage "preflight"
# deploy は release directory を最後に atomic symlink で切り替える方式にする。
# そのため、ここから current 切り替えまでの失敗は現行 release に影響しない。
# ただし migration は DB に反映されるため、rollback しても自動 down は行わない。
log "Rails API deploy を開始します。deploy 元=${RAILS_REPO_URL} ref=${REF}"
log "外付け HDD、環境変数ファイル、保存先権限を先に検査します。"
require_mountpoint "${EXTERNAL_HDD}"
require_readable_dir "${DRIVE_ITEMS_ROOT}"
require_writable_dir "${DRIVE_ITEMS_ROOT}"
require_filesystem_rw "${DRIVE_ITEMS_ROOT}"
[[ -f "${RAILS_ENV_FILE}" ]] || die "missing env file: ${RAILS_ENV_FILE}"
load_systemd_env_file "${RAILS_ENV_FILE}"
[[ "${FILE_STORAGE_ROOT:-}" == "/mnt/external-hdd/mitsubachi/files" ]] || die "FILE_STORAGE_ROOT must be /mnt/external-hdd/mitsubachi/files"
missing_database_urls=()
for database_url_key in DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL; do
  if [[ -z "${!database_url_key:-}" ]]; then
    missing_database_urls+=("${database_url_key}")
  fi
done
if ((${#missing_database_urls[@]} > 0)); then
  die "Rails production の複数DB設定が不足しています: ${missing_database_urls[*]}。単一 DATABASE_URL だけの旧構成では deploy できません。"
fi
log "Rails production 用の4つの DATABASE URL が設定済みであることを確認しました。値は表示しません。"
ensure_dir "deploy:deploy" 0755 "${APP_ROOT}" "${REPO_CACHE}" "${RELEASE_ROOT}" "${SHARED_ROOT}" "${SHARED_ROOT}/log" "${SHARED_ROOT}/tmp"
touch "${DEPLOY_LOG}"

tmp_release=""
previous_release=""
release_switched=false
cleanup_failed_release() {
  if [[ "${release_switched}" != true && -n "${tmp_release}" && -d "${tmp_release}" ]]; then
    rm -rf -- "${tmp_release}"
  fi
}
trap cleanup_failed_release EXIT

set_stage "repository fetch"
log "Rails API リポジトリを /var/www/mitsubachi/repo へ clone/fetch します。Infra リポジトリ内へ Rails コードは置きません。"
if [[ ! -d "${REPO_CACHE}/.git" ]]; then
  rm -rf -- "${REPO_CACHE}"
  git clone --mirror -- "${RAILS_REPO_URL}" "${REPO_CACHE}"
else
  git -C "${REPO_CACHE}" remote set-url origin "${RAILS_REPO_URL}"
  git -C "${REPO_CACHE}" remote update --prune
fi

set_stage "resolve ref"
log "指定 ref を commit SHA に固定します。以降の release はこの SHA だけから作成します。"
COMMIT_SHA="$(git -C "${REPO_CACHE}" rev-parse --verify "${REF}^{commit}")"
[[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || die "failed to resolve commit SHA for ref: ${REF}"
short_sha="${COMMIT_SHA:0:12}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
release_name="${timestamp}-${short_sha}"
validate_safe_basename "${release_name}"
tmp_release="${RELEASE_ROOT}/${release_name}"
[[ ! -e "${tmp_release}" ]] || die "release already exists: ${tmp_release}"
mkdir -p -- "${tmp_release}"
# repo cache は mirror として保持し、実行中アプリケーションの作業ツリーにはしない。
# release directory へ commit SHA を直接 checkout することで、deploy 対象が
# ref の移動に影響されず、後から deployments.log の SHA と実ファイルを追跡できる。
git --git-dir="${REPO_CACHE}" --work-tree="${tmp_release}" checkout -f "${COMMIT_SHA}" -- .
log "release directory を作成しました: ${release_name}"

set_stage "ruby and bundler"
log "Rails API の .ruby-version / Gemfile.lock に従って Ruby と Bundler を確認します。"
cd "${tmp_release}"
if [[ -f .ruby-version ]]; then
  ruby_version="$(tr -d '[:space:]' < .ruby-version)"
  if command -v rbenv >/dev/null 2>&1; then
    rbenv versions --bare | grep -Fx -- "${ruby_version}" >/dev/null || die "Ruby ${ruby_version} is not installed"
  fi
fi
if [[ -f Gemfile.lock ]]; then
  bundler_version="$(awk '/^BUNDLED WITH$/ {getline; gsub(/^[[:space:]]+/, "", $0); print; exit}' Gemfile.lock)"
  if [[ -n "${bundler_version}" ]]; then
    gem list -i bundler -v "${bundler_version}" >/dev/null || gem install bundler -v "${bundler_version}"
  fi
fi
bundle config set --local deployment true
bundle config set --local without "development test"
bundle install

set_stage "shared paths"
# log/tmp は release ごとに消えると調査や pid 管理が不安定になるため shared へ
# symlink する。Rails コード本体だけを release directory として世代管理する。
log "shared log/tmp を release へ接続します。"
rm -rf -- log tmp
ln -s -- "${SHARED_ROOT}/log" log
ln -s -- "${SHARED_ROOT}/tmp" tmp
mkdir -p -- tmp/pids tmp/cache tmp/sockets

set_stage "rails checks"
log "production boot check と DB 接続確認を実行します。秘密情報は表示しません。"
bundle exec rails runner 'Rails.application.eager_load!; puts "boot-ok"'
bundle exec rails runner 'ActiveRecord::Base.connection.execute("SELECT 1"); puts "db-ok"'
if [[ "${SKIP_MIGRATE}" != true ]]; then
  log "db:migrate を実行します。失敗時も migration の自動 down は行いません。"
  bundle exec rails db:migrate
else
  log "--skip-migrate 指定のため db:migrate は実行しません。"
fi

set_stage "switch release"
log "current symlink を atomic に切り替えます。"
if [[ -L "${CURRENT_LINK}" ]]; then
  previous_release="$(readlink -f -- "${CURRENT_LINK}")"
fi
atomic_symlink_switch "${tmp_release}" "${CURRENT_LINK}"
release_switched=true

set_stage "restart and health"
if [[ "${SKIP_RESTART}" != true ]]; then
  log "systemd service を再起動し、ready health が HTTP 200 になるまで確認します。"
  systemctl --user status >/dev/null 2>&1 || true
  if command -v systemctl >/dev/null 2>&1; then
    sudo -n systemctl restart "${SERVICE_NAME}.service" || die "failed to restart ${SERVICE_NAME}; configure passwordless sudo for deploy or restart manually with --skip-restart"
    if ! health_check_retry "${HEALTH_URL}" 30 2 "${HEALTH_HOST}"; then
      if [[ -n "${previous_release}" && -d "${previous_release}" ]]; then
        log "health check 失敗のため、current symlink を直前 release へ戻します: ${previous_release}"
        atomic_symlink_switch "${previous_release}" "${CURRENT_LINK}"
        sudo -n systemctl restart "${SERVICE_NAME}.service" || true
        health_check_retry "${HEALTH_URL}" 30 2 "${HEALTH_HOST}"
      fi
      die "deployment health check failed"
    fi
  fi
else
  log "--skip-restart 指定のため service restart と health check は実行しません。"
fi

set_stage "cleanup releases"
log "古い release を整理します。ただし current が指す release は削除しません。keep=${KEEP_RELEASES}"
current_real="$(readlink -f -- "${CURRENT_LINK}")"
find "${RELEASE_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
  | sort -rn \
  | awk -v keep="${KEEP_RELEASES}" 'NR > keep {sub(/^[^ ]+ /, ""); print}' \
  | while IFS= read -r old_release; do
      [[ "$(readlink -f -- "${old_release}")" != "${current_real}" ]] || continue
      rm -rf -- "${old_release}"
    done

set_stage "deployment log"
printf '%s deploy release=%s commit=%s ref=%s repo=%s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${release_name}" "${COMMIT_SHA}" "${REF}" "${RAILS_REPO_URL}" >> "${DEPLOY_LOG}"
log "deploy 完了: release=${release_name} commit=${COMMIT_SHA}"
