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
  "${FILE_STORAGE_ROOT}" "${DRIVE_ITEMS_ROOT}" \
  "${MITSUBACHI_HDD_ROOT}/tmp" "${BULK_DOWNLOAD_TMP}"
ensure_dir "root:root" 0700 \
  "${MITSUBACHI_HDD_ROOT}/backups" "${POSTGRES_BACKUP_DIR}" "${STORAGE_BACKUP_DIR}"
chmod 0750 "${FILE_STORAGE_ROOT}" "${DRIVE_ITEMS_ROOT}" "${MITSUBACHI_HDD_ROOT}/tmp" "${BULK_DOWNLOAD_TMP}"
chmod g+s "${FILE_STORAGE_ROOT}" "${DRIVE_ITEMS_ROOT}" "${MITSUBACHI_HDD_ROOT}/tmp" "${BULK_DOWNLOAD_TMP}"

set_stage "optional version discovery"
log "Rails API リポジトリから Ruby / Bundler version を必要に応じて検出します。"
tmp_repo=""
cleanup() {
  [[ -n "${tmp_repo}" && -d "${tmp_repo}" ]] && rm -rf -- "${tmp_repo}"
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
if ! run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" versions --bare | grep -Fx -- "${RUBY_VERSION}" >/dev/null; then
  run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" install "${RUBY_VERSION}"
fi
run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" global "${RUBY_VERSION}"
if [[ -n "${BUNDLER_VERSION}" ]]; then
  run_as_deploy_home gem install bundler -v "${BUNDLER_VERSION}"
else
  run_as_deploy_home gem install bundler
fi
run_as_deploy_home "${DEPLOY_HOME}/.rbenv/bin/rbenv" rehash

set_stage "postgres optional create"
log "PostgreSQL role/database は明示指定された場合だけ冪等に作成します。既存 DB は削除しません。"
if [[ -n "${CREATE_DB}" || -n "${CREATE_DB_ROLE}" ]]; then
  [[ -n "${CREATE_DB}" && -n "${CREATE_DB_ROLE}" ]] || die "--create-db and --create-db-role must be supplied together"
  [[ "${CREATE_DB}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "unsafe database name"
  [[ "${CREATE_DB_ROLE}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "unsafe database role"
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${CREATE_DB_ROLE}') THEN
    CREATE ROLE "${CREATE_DB_ROLE}" LOGIN;
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE "${CREATE_DB}" OWNER "${CREATE_DB_ROLE}"'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${CREATE_DB}')\gexec
SQL
fi

set_stage "nginx and systemd install"
log "指定された場合のみ Nginx / systemd 設定を install します。既存ファイルは事前に backup します。"
if [[ "${INSTALL_NGINX}" == true ]]; then
  backup_if_exists /etc/nginx/sites-available/mitsubachi-local.conf
  install -o root -g root -m 0644 "${REPO_ROOT}/nginx/mitsubachi-local.conf" /etc/nginx/sites-available/mitsubachi-local.conf
  ln -sfn /etc/nginx/sites-available/mitsubachi-local.conf /etc/nginx/sites-enabled/mitsubachi-local.conf
  if [[ "${REMOVE_DEFAULT}" == true ]]; then
    backup_if_exists /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default
  fi
  nginx -t
  systemctl reload nginx || systemctl restart nginx
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
