#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: sudo scripts/bootstrap_ubuntu.sh [options]

Options:
  --ruby-version VERSION       Ruby version to install with rbenv.
  --bundler-version VERSION    Bundler version to install.
  --app-repo URL               Read .ruby-version and Gemfile.lock from this Rails repo when versions are omitted.
  --install-nginx-config       Install nginx/mitsubachi-local.conf into sites-available and enable it.
  --install-systemd-unit       Install systemd/mitsubachi-api.service.
  --remove-default-site        Remove Nginx default site symlink. Requires --install-nginx-config.
  --create-db NAME             Create PostgreSQL database when used with --create-db-role.
  --create-db-role ROLE        Create PostgreSQL role when used with --create-db.
  --help                       Show this help.
USAGE
}

RUBY_VERSION=""
BUNDLER_VERSION=""
APP_REPO=""
INSTALL_NGINX=false
INSTALL_SYSTEMD=false
REMOVE_DEFAULT=false
CREATE_DB=""
CREATE_DB_ROLE=""
DEPLOY_USER="deploy"
DEPLOY_HOME=""
NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
NGINX_BACKUP_DIR="${NGINX_BACKUP_DIR:-/etc/nginx/backups}"
NGINX_LOCAL_CONF_NAME="mitsubachi-local.conf"
NGINX_DEFAULT_SITE_NAME="default"

while (($#)); do
  case "$1" in
    --ruby-version) RUBY_VERSION="${2:-}"; shift 2 ;;
    --bundler-version) BUNDLER_VERSION="${2:-}"; shift 2 ;;
    --app-repo) APP_REPO="${2:-}"; shift 2 ;;
    --install-nginx-config) INSTALL_NGINX=true; shift ;;
    --install-systemd-unit) INSTALL_SYSTEMD=true; shift ;;
    --remove-default-site) REMOVE_DEFAULT=true; shift ;;
    --create-db) CREATE_DB="${2:-}"; shift 2 ;;
    --create-db-role) CREATE_DB_ROLE="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
require_command apt-get git curl install useradd usermod getent sudo

resolve_deploy_home() {
  DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
  [[ -n "${DEPLOY_HOME}" ]] || die "${DEPLOY_USER} ユーザーの HOME を解決できません。useradd が失敗していないか確認してください。"
}

run_as_deploy_home() {
  [[ -n "${DEPLOY_HOME}" ]] || resolve_deploy_home
  log "running as ${DEPLOY_USER} from ${DEPLOY_HOME}: $*"
  # sudo はユーザー切替だけに使い、実際の Git / rbenv / Ruby / Bundler は
  # deploy の HOME と PATH で実行する。bash wrapper 内で cd "$HOME" してから
  # 引数配列をそのまま実行することで、呼び出し元が /home/sio など deploy から
  # 読めない作業ディレクトリにいても ruby-build の pushd/popd が壊れない。
  sudo -u "${DEPLOY_USER}" -H \
    env HOME="${DEPLOY_HOME}" \
        RBENV_ROOT="${DEPLOY_HOME}/.rbenv" \
        PATH="${DEPLOY_HOME}/.rbenv/bin:${DEPLOY_HOME}/.rbenv/shims:/usr/local/bin:/usr/bin:/bin" \
    bash -c 'set -Eeuo pipefail; cd "$HOME"; "$@"' bash "$@"
}

ruby_is_installed() {
  local ruby_version="$1"
  # shellcheck disable=SC2016
  run_as_deploy_home bash -c '
    set -Eeuo pipefail
    ruby_version="$1"
    ruby_path="${RBENV_ROOT}/versions/${ruby_version}/bin/ruby"
    [[ -x "${ruby_path}" ]] || exit 1
    actual_version="$("${ruby_path}" -e "print RUBY_VERSION")"
    [[ "${actual_version}" == "${ruby_version}" ]]
  ' bash "${ruby_version}"
}

bundler_is_installed() {
  local bundler_version="$1"
  if [[ -n "${bundler_version}" ]]; then
    run_as_deploy_home gem list --installed --exact bundler --version "${bundler_version}"
  else
    run_as_deploy_home bundle --version
  fi
}

url_decode_component() {
  local value="$1"
  printf '%b' "${value//%/\\x}"
}

sql_literal() {
  local value="$1"
  local quote="'"
  local escaped
  escaped="${value//${quote}/${quote}${quote}}"
  printf "'%s'" "${escaped}"
}

parse_database_url_for_postgres_bootstrap() {
  local env_key="$1"
  local expected_db="$2"
  local url authority_path authority userinfo hostport encoded_role encoded_password encoded_db
  url="${!env_key:-}"
  [[ -n "${url}" ]] || die "CREATE_DB 指定時は ${RAILS_ENV_FILE} の ${env_key} が必要です。"
  case "${url}" in
    postgres://*|postgresql://*) ;;
    *) die "DATABASE_URL は postgres:// または postgresql:// 形式である必要があります。" ;;
  esac
  authority_path="${url#*://}"
  authority="${authority_path%%/*}"
  encoded_db="${authority_path#*/}"
  encoded_db="${encoded_db%%\?*}"
  encoded_db="${encoded_db%%#*}"
  [[ "${authority}" == *"@"* ]] || die "DATABASE_URL に PostgreSQL user/password が含まれていません。"
  userinfo="${authority%@*}"
  hostport="${authority#*@}"
  [[ "${userinfo}" == *":"* ]] || die "DATABASE_URL に PostgreSQL password が含まれていません。"
  encoded_role="${userinfo%%:*}"
  encoded_password="${userinfo#*:}"
  local parsed_role parsed_password parsed_database parsed_host parsed_port
  parsed_role="$(url_decode_component "${encoded_role}")"
  parsed_password="$(url_decode_component "${encoded_password}")"
  parsed_database="$(url_decode_component "${encoded_db}")"
  parsed_host="${hostport%%:*}"
  if [[ "${hostport}" == *":"* ]]; then
    parsed_port="${hostport##*:}"
  else
    parsed_port="5432"
  fi
  [[ "${parsed_role}" == "${CREATE_DB_ROLE}" ]] || die "${env_key} の role と --create-db-role が一致しません。"
  [[ "${parsed_database}" == "${expected_db}" ]] || die "${env_key} の database は ${expected_db} である必要があります。"
  [[ "${parsed_host}" == "127.0.0.1" ]] || die "${env_key} の host は 127.0.0.1 に固定してください。"
  [[ -n "${parsed_password}" ]] || die "${env_key} の PostgreSQL password が空です。"
  [[ "${parsed_port}" =~ ^[0-9]+$ ]] || die "${env_key} の PostgreSQL port が不正です。"
  if [[ -z "${POSTGRES_URL_ROLE:-}" ]]; then
    POSTGRES_URL_ROLE="${parsed_role}"
    POSTGRES_URL_PASSWORD="${parsed_password}"
    POSTGRES_URL_HOST="${parsed_host}"
    POSTGRES_URL_PORT="${parsed_port}"
  else
    [[ "${POSTGRES_URL_ROLE}" == "${parsed_role}" ]] || die "4つの DATABASE URL の role が一致しません。"
    [[ "${POSTGRES_URL_PASSWORD}" == "${parsed_password}" ]] || die "4つの DATABASE URL の password が一致しません。"
    [[ "${POSTGRES_URL_HOST}" == "${parsed_host}" ]] || die "4つの DATABASE URL の host が一致しません。"
    [[ "${POSTGRES_URL_PORT}" == "${parsed_port}" ]] || die "4つの DATABASE URL の port が一致しません。"
  fi
}

psql_scalar_as_postgres() {
  local sql="$1"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -Atqc "${sql}"
}

ensure_postgres_role_database() {
  [[ -n "${CREATE_DB}" && -n "${CREATE_DB_ROLE}" ]] || die "--create-db and --create-db-role must be supplied together"
  [[ "${CREATE_DB}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "unsafe database name"
  [[ "${CREATE_DB_ROLE}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "unsafe database role"
  load_systemd_env_file "${RAILS_ENV_FILE}"
  local db_names=(mitsubachi_production mitsubachi_production_cache mitsubachi_production_queue mitsubachi_production_cable)
  local env_keys=(DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL)
  local i db_name
  [[ "${CREATE_DB}" == "mitsubachi_production" ]] || die "--create-db は mitsubachi_production に固定してください。"
  [[ "${CREATE_DB_ROLE}" == "mitsubachi" ]] || die "--create-db-role は mitsubachi に固定してください。"
  POSTGRES_URL_ROLE=""
  POSTGRES_URL_PASSWORD=""
  POSTGRES_URL_HOST=""
  POSTGRES_URL_PORT=""
  for i in "${!env_keys[@]}"; do
    parse_database_url_for_postgres_bootstrap "${env_keys[$i]}" "${db_names[$i]}"
  done

  local role_exists db_owner password_sql
  role_exists="$(psql_scalar_as_postgres "SELECT 1 FROM pg_roles WHERE rolname = $(sql_literal "${CREATE_DB_ROLE}")")"
  if [[ "${role_exists}" == "1" ]]; then
    log "PostgreSQL role は既に存在するため password は変更しません: ${CREATE_DB_ROLE}"
  else
    password_sql="$(sql_literal "${POSTGRES_URL_PASSWORD}")"
    printf 'CREATE ROLE "%s" LOGIN PASSWORD %s;\n' "${CREATE_DB_ROLE}" "${password_sql}" |
      sudo -u postgres psql -v ON_ERROR_STOP=1
    log "PostgreSQL role を作成しました: ${CREATE_DB_ROLE}"
  fi

  for db_name in "${db_names[@]}"; do
    db_owner="$(psql_scalar_as_postgres "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = $(sql_literal "${db_name}")")"
    if [[ -z "${db_owner}" ]]; then
      printf 'CREATE DATABASE "%s" OWNER "%s";\n' "${db_name}" "${CREATE_DB_ROLE}" |
        sudo -u postgres psql -v ON_ERROR_STOP=1
      log "PostgreSQL database を作成しました: ${db_name}"
    elif [[ "${db_owner}" == "${CREATE_DB_ROLE}" ]]; then
      log "PostgreSQL database は既に存在し、owner も一致しています: ${db_name}"
    else
      die "PostgreSQL database owner が一致しません。database=${db_name} owner=${db_owner} expected=${CREATE_DB_ROLE}"
    fi
  done

  for db_name in "${db_names[@]}"; do
    if PGPASSWORD="${POSTGRES_URL_PASSWORD}" psql \
      -h "${POSTGRES_URL_HOST}" \
      -p "${POSTGRES_URL_PORT}" \
      -U "${CREATE_DB_ROLE}" \
      -d "${db_name}" \
      -v ON_ERROR_STOP=1 \
      -Atqc 'SELECT 1' >/dev/null; then
      log "PostgreSQL role/database/password の接続確認に成功しました: role=${CREATE_DB_ROLE} database=${db_name}"
    else
      die "PostgreSQL 接続確認に失敗しました。既存 role の password 不一致、pg_hba.conf、host/port、database owner を確認してください。database=${db_name}"
    fi
  done
}

nginx_backup_path() {
  local path="$1"
  local timestamp="$2"
  local base parent
  base="$(basename -- "${path}")"
  parent="$(basename -- "$(dirname -- "${path}")")"
  printf '%s/%s.%s.%s\n' "${NGINX_BACKUP_DIR}" "${parent}" "${base}" "${timestamp}"
}

backup_nginx_path_outside_include() {
  local path="$1"
  local timestamp="$2"
  local backup
  install -d -o root -g root -m 0755 -- "${NGINX_BACKUP_DIR}"
  if [[ -e "${path}" || -L "${path}" ]]; then
    backup="$(nginx_backup_path "${path}" "${timestamp}")"
    if [[ -L "${path}" ]]; then
      log "Nginx 有効設定 symlink を include 対象外へ退避します: ${path} -> $(readlink -- "${path}")"
    fi
    cp -a -- "${path}" "${backup}"
    log "Nginx 設定を include 対象外へ退避しました: ${path} -> ${backup}"
    printf '%s\n' "${backup}"
  fi
}

restore_nginx_path() {
  local backup="$1"
  local path="$2"
  local keep_existing="${3:-false}"
  if [[ "${keep_existing}" == true ]]; then
    log "既存 Nginx 設定をロールバック後も保持します: ${path}"
    return 0
  fi
  rm -f -- "${path}"
  if [[ -n "${backup}" && ( -e "${backup}" || -L "${backup}" ) ]]; then
    cp -a -- "${backup}" "${path}"
    log "Nginx 設定を復元しました: ${backup} -> ${path}"
  else
    log "復元対象がないため Nginx 設定を無効状態に戻しました: ${path}"
  fi
}

move_misplaced_enabled_backups() {
  local timestamp="$1"
  local path dest base
  shopt -s nullglob
  for path in "${NGINX_SITES_ENABLED}"/*.bak*; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    install -d -o root -g root -m 0755 -- "${NGINX_BACKUP_DIR}"
    base="$(basename -- "${path}")"
    dest="${NGINX_BACKUP_DIR}/${base}.moved.${timestamp}"
    while [[ -e "${dest}" || -L "${dest}" ]]; do
      dest="${dest}.$$"
    done
    mv -T -- "${path}" "${dest}"
    log "include 対象に残っていた過去の Nginx backup を退避しました: ${path} -> ${dest}"
  done
  shopt -u nullglob
}

install_nginx_local_config() {
  local timestamp available_path enabled_path default_path
  local previous_available_backup="" previous_enabled_backup="" previous_default_backup=""
  local keep_available_on_rollback=false keep_enabled_on_rollback=false enabled_points_to_local=false
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  available_path="${NGINX_SITES_AVAILABLE}/${NGINX_LOCAL_CONF_NAME}"
  enabled_path="${NGINX_SITES_ENABLED}/${NGINX_LOCAL_CONF_NAME}"
  default_path="${NGINX_SITES_ENABLED}/${NGINX_DEFAULT_SITE_NAME}"

  move_misplaced_enabled_backups "${timestamp}"

  if [[ -e "${available_path}" || -L "${available_path}" ]]; then
    if cmp -s -- "${REPO_ROOT}/nginx/mitsubachi-local.conf" "${available_path}"; then
      log "Nginx sites-available の Mitsubachi 設定は既に同一内容です。バックアップ作成をスキップします。"
      keep_available_on_rollback=true
    else
      previous_available_backup="$(backup_nginx_path_outside_include "${available_path}" "${timestamp}")"
    fi
  fi

  if [[ -L "${enabled_path}" && "$(readlink -f -- "${enabled_path}")" == "$(readlink -f -- "${available_path}" 2>/dev/null || printf '%s' "${available_path}")" ]]; then
    enabled_points_to_local=true
    keep_enabled_on_rollback=true
    log "Nginx sites-enabled の Mitsubachi symlink は既に正しいため保持します。"
  elif [[ -e "${enabled_path}" || -L "${enabled_path}" ]]; then
    previous_enabled_backup="$(backup_nginx_path_outside_include "${enabled_path}" "${timestamp}")"
    rm -f -- "${enabled_path}"
    log "既存の Mitsubachi 有効設定を一度無効化しました: ${enabled_path}"
  fi

  if [[ "${REMOVE_DEFAULT}" == true && ( -e "${default_path}" || -L "${default_path}" ) ]]; then
    previous_default_backup="$(backup_nginx_path_outside_include "${default_path}" "${timestamp}")"
    rm -f -- "${default_path}"
    log "Nginx default site を include 対象から無効化しました: ${default_path}"
  fi

  install -o root -g root -m 0644 "${REPO_ROOT}/nginx/mitsubachi-local.conf" "${available_path}"
  [[ "${enabled_points_to_local}" == true ]] || ln -sfn "${available_path}" "${enabled_path}"

  if ! nginx -t; then
    log "Nginx 設定検査に失敗したため、新設定を外して旧設定へロールバックします。"
    restore_nginx_path "${previous_available_backup}" "${available_path}" "${keep_available_on_rollback}"
    restore_nginx_path "${previous_enabled_backup}" "${enabled_path}" "${keep_enabled_on_rollback}"
    if [[ "${REMOVE_DEFAULT}" == true ]]; then
      restore_nginx_path "${previous_default_backup}" "${default_path}" false
    fi
    if nginx -t; then
      log "ロールバック後の Nginx 設定検査は成功しました。"
    else
      log "ロールバック後も Nginx 設定検査が失敗しました。既存設定を手動確認してください。"
    fi
    die "Nginx 設定検査に失敗したため install を中止しました。"
  fi

  systemctl reload nginx || systemctl restart nginx
}

if [[ "${REMOVE_DEFAULT}" == true && "${INSTALL_NGINX}" != true ]]; then
  die "--remove-default-site requires --install-nginx-config"
fi

set_stage "apt packages"
log "Ubuntu 初期構築を開始します。Ruby build、PostgreSQL、Nginx、UFW、検証用 shellcheck を導入します。"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  git curl ca-certificates build-essential autoconf bison pkg-config \
  libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev libgdbm-dev \
  libncurses5-dev libpq-dev postgresql postgresql-contrib nginx ufw tar rsync \
  jq shellcheck

set_stage "users and groups"
log "deploy ユーザーと storage 共有 group を確認します。既存ユーザーは破壊的に変更しません。"
if ! getent group mitsubachi-files >/dev/null; then
  groupadd --system mitsubachi-files
fi
if ! id deploy >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --user-group deploy
fi
resolve_deploy_home
usermod -aG mitsubachi-files deploy
usermod -aG mitsubachi-files www-data

set_stage "base directories"
log "release directory 方式のための /var/www/mitsubachi 配下を作成します。"
ensure_dir "deploy:deploy" 0755 \
  "${APP_ROOT}" "${REPO_CACHE}" "${RELEASE_ROOT}" "${SHARED_ROOT}" \
  "${SHARED_ROOT}/log" "${SHARED_ROOT}/tmp"
touch "${DEPLOY_LOG}"
chown deploy:deploy "${DEPLOY_LOG}"
chmod 0644 "${DEPLOY_LOG}"
ensure_dir "root:deploy" 0750 /etc/mitsubachi

set_stage "external hdd directories"
# 外付け HDD 配下は mountpoint 確認後にだけ作る。ここを省くと、
# HDD 未接続時に /mnt/external-hdd という通常ディレクトリへ保存され、
# 後から HDD を mount した時にデータが隠れてしまう。これは復旧時に非常に
# 分かりにくい事故になるため、初期構築時点から強制的に止める。
log "外付け HDD の mount 状態と書き込み可否を確認してから Mitsubachi 用ディレクトリを作成します。"
require_mountpoint "${EXTERNAL_HDD}"
require_filesystem_rw "${EXTERNAL_HDD}"
ensure_dir "root:mitsubachi-files" 0750 "${MITSUBACHI_HDD_ROOT}"
ensure_dir "deploy:mitsubachi-files" 0750 \
  "${FILE_STORAGE_ROOT}" "${DRIVE_ITEMS_ROOT}" "${PREVIEW_ROOT}" \
  "${MITSUBACHI_HDD_ROOT}/tmp" "${BULK_DOWNLOAD_TMP}"
ensure_dir "root:root" 0700 \
  "${MITSUBACHI_HDD_ROOT}/backups" "${POSTGRES_BACKUP_DIR}" "${STORAGE_BACKUP_DIR}"
chmod 0750 "${FILE_STORAGE_ROOT}" "${DRIVE_ITEMS_ROOT}" "${PREVIEW_ROOT}" "${MITSUBACHI_HDD_ROOT}/tmp" "${BULK_DOWNLOAD_TMP}"
chmod g+s "${FILE_STORAGE_ROOT}" "${DRIVE_ITEMS_ROOT}" "${PREVIEW_ROOT}" "${MITSUBACHI_HDD_ROOT}/tmp" "${BULK_DOWNLOAD_TMP}"

set_stage "optional version discovery"
log "Rails API リポジトリから Ruby / Bundler version を必要に応じて検出します。"
tmp_repo=""
cleanup() {
  if [[ -n "${tmp_repo}" && -d "${tmp_repo}" ]]; then
    rm -rf -- "${tmp_repo}"
  fi
  return 0
}
trap cleanup EXIT
if [[ -n "${APP_REPO}" && ( -z "${RUBY_VERSION}" || -z "${BUNDLER_VERSION}" ) ]]; then
  require_command git
  tmp_repo="$(mktemp -d)"
  chown deploy:deploy "${tmp_repo}"
  # Rails repository may be private.  Version discovery must therefore use the
  # same deploy user's SSH configuration as real deployments, never root's
  # /root/.ssh created by sudo execution.  The helper also moves into deploy's
  # HOME before running git so root's or the invoking user's cwd cannot leak in.
  if run_as_deploy_home git clone --depth 1 -- "${APP_REPO}" "${tmp_repo}"; then
    if [[ -z "${RUBY_VERSION}" && -f "${tmp_repo}/.ruby-version" ]]; then
      RUBY_VERSION="$(tr -d '[:space:]' < "${tmp_repo}/.ruby-version")"
    fi
    if [[ -z "${BUNDLER_VERSION}" && -f "${tmp_repo}/Gemfile.lock" ]]; then
      BUNDLER_VERSION="$(awk '/^BUNDLED WITH$/ {getline; gsub(/^[[:space:]]+/, "", $0); print; exit}' "${tmp_repo}/Gemfile.lock")"
    fi
  else
    log "任意の Ruby/Bundler version discovery に失敗しました。APP_REPO=${APP_REPO} user=${DEPLOY_USER} HOME=${DEPLOY_HOME} SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-未設定}。通常ユーザーで ssh -T git@github.com と git ls-remote を確認してください。既定 version で続行します。"
  fi
fi
RUBY_VERSION="${RUBY_VERSION:-3.3.6}"
BUNDLER_VERSION="${BUNDLER_VERSION:-}"

set_stage "rbenv"
log "deploy ユーザーの home に rbenv / ruby-build / Bundler を構築します。systemd は .bashrc に依存しません。"
if [[ ! -d "${DEPLOY_HOME}/.rbenv" ]]; then
  run_as_deploy_home git clone https://github.com/rbenv/rbenv.git "${DEPLOY_HOME}/.rbenv"
fi
if [[ ! -d "${DEPLOY_HOME}/.rbenv/plugins/ruby-build" ]]; then
  run_as_deploy_home git clone https://github.com/rbenv/ruby-build.git "${DEPLOY_HOME}/.rbenv/plugins/ruby-build"
fi
if ruby_is_installed "${RUBY_VERSION}"; then
  log "Ruby ${RUBY_VERSION} は deploy ユーザーの rbenv にインストール済みです。ビルドをスキップします。"
else
  log "Ruby ${RUBY_VERSION} が未導入、または不完全です。deploy ユーザーでビルドします。"
  run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" install "${RUBY_VERSION}"
fi
run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" global "${RUBY_VERSION}"
if [[ -n "${BUNDLER_VERSION}" ]]; then
  if bundler_is_installed "${BUNDLER_VERSION}"; then
    log "Bundler ${BUNDLER_VERSION} はインストール済みです。install をスキップします。"
  else
    run_as_deploy_home gem install bundler --version "${BUNDLER_VERSION}" --no-document
  fi
else
  if bundler_is_installed ""; then
    log "Bundler は既に利用可能です。最新版 install をスキップします。"
  else
    run_as_deploy_home gem install bundler --no-document
  fi
fi
run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" rehash

set_stage "postgres optional create"
log "PostgreSQL role/database は明示指定された場合だけ冪等に作成します。既存 DB は削除しません。"
if [[ -n "${CREATE_DB}" || -n "${CREATE_DB_ROLE}" ]]; then
  ensure_postgres_role_database
fi

set_stage "nginx and systemd install"
log "指定された場合のみ Nginx / systemd 設定を install します。既存ファイルは事前に backup します。"
if [[ "${INSTALL_NGINX}" == true ]]; then
  install_nginx_local_config
fi

if [[ "${INSTALL_SYSTEMD}" == true ]]; then
  backup_if_exists /etc/systemd/system/mitsubachi-api.service
  install -o root -g root -m 0644 "${REPO_ROOT}/systemd/mitsubachi-api.service" /etc/systemd/system/mitsubachi-api.service
  systemctl daemon-reload
  systemctl enable mitsubachi-api.service
  if [[ -L "${CURRENT_LINK}" && -f "${RAILS_ENV_FILE}" ]]; then
    log "current release と環境変数ファイルが存在するため、mitsubachi-api を再起動します。"
    systemctl restart mitsubachi-api.service
  else
    log "mitsubachi-api は enable 済みです。current release または env file が未作成のため、起動は行いません。"
  fi
fi

log "Ubuntu 初期構築が完了しました。"
