#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/install_local.sh [options]

Options:
  --config PATH                 Non-secret install config. Default candidate: config/local.env.
  --rails-env-file PATH          Rails env input file. Installed destination remains /etc/mitsubachi/rails.env.
  --interactive                  Prompt for missing values. Requires stdin/stdout TTY.
  --non-interactive              Never prompt; fail if required values are missing.
  --yes                          Skip final confirmation.
  --dry-run                      Resolve values and print summary without writing files or running install steps.
  --overwrite-rails-env          Replace an existing rails env file after creating timestamp backup.
  --update-rails-env             Allow changing existing non-secret rails env keys.
  --update-secrets               Allow changing existing secret rails env keys.
  --server-ip IP                 Ubuntu server private IP.
  --lan-cidr CIDR                LAN CIDR allowed to access HTTP/SSH.
  --rails-repo-url URL           Rails API deploy source. Default: git@github.com:ShioPy0101/mitsubachi-ruby.git.
  --rails-ref REF                Rails ref to deploy. Default: main.
  --deploy-user USER             Rails service user. Default: deploy.
  --deploy-group GROUP           Rails service group. Default: deploy.
  --postgres-role ROLE           PostgreSQL role name used when composing DATABASE_URL interactively.
  --postgres-database NAME       PostgreSQL database name used when composing DATABASE_URL interactively.
  --keep-releases N              Release retention count. Default: 5.
  --enable-ufw BOOL              yes/no/true/false/1/0.
  --allow-ssh BOOL               yes/no/true/false/1/0.
  --remove-nginx-default-site BOOL
                                  yes/no/true/false/1/0.
  --rails-master-key VALUE       Secret. Prefer interactive input or --rails-env-file over CLI.
  --secret-key-base VALUE        Secret. Prefer interactive input or --rails-env-file over CLI.
  --database-url VALUE           Secret. Prefer interactive input or --rails-env-file over CLI.
  --database-cache-url VALUE     Secret. Prefer interactive input or --rails-env-file over CLI.
  --database-queue-url VALUE     Secret. Prefer interactive input or --rails-env-file over CLI.
  --database-cable-url VALUE     Secret. Prefer interactive input or --rails-env-file over CLI.
  --resend-api-key VALUE         Secret. Prefer interactive input or --rails-env-file over CLI.
  --mail-from VALUE              Mail From address.
  --app-host VALUE               Rails APP_HOST. Default: SERVER_IP.
  --frontend-origin URL          Default: http://SERVER_IP.
  --frontend-url URL             Default: http://SERVER_IP.
  --session-cookie-secure BOOL   Default: false for LAN HTTP.
  --help                         Show this help.
USAGE
}

declare -A values sources cli_values config_values existing_env
declare -A secret_key

secret_key[RAILS_MASTER_KEY]=true
secret_key[SECRET_KEY_BASE]=true
secret_key[DATABASE_URL]=true
secret_key[DATABASE_CACHE_URL]=true
secret_key[DATABASE_QUEUE_URL]=true
secret_key[DATABASE_CABLE_URL]=true
secret_key[RESEND_API_KEY]=true

CONFIG_FILE=""
RAILS_ENV_DEST="/etc/mitsubachi/rails.env"
RAILS_ENV_INPUT_FILE=""
RAILS_ENV_FILE_EXPLICIT=false
INTERACTIVE_FLAG=false
NON_INTERACTIVE_FLAG=false
YES=false
DRY_RUN=false
OVERWRITE_RAILS_ENV=false
UPDATE_RAILS_ENV=false
UPDATE_SECRETS=false
SECRET_KEY_BASE_OMITTED=false

INVOKING_USER="${SUDO_USER:-$(id -un)}"
INVOKING_HOME="$(getent passwd "${INVOKING_USER}" | cut -d: -f6)"
[[ -n "${INVOKING_HOME}" ]] || die "呼び出し元ユーザー ${INVOKING_USER} の HOME を getent passwd から解決できません。"

if [[ "${EUID}" -eq 0 ]]; then
  die "install_local.sh は root で実行しないでください。通常ユーザーで ./scripts/install_local.sh を実行し、必要な処理だけ sudo します。root の HOME や SSH 鍵を使わないために停止します。"
fi

sudo_cmd() {
  log "running as root via sudo: $*"
  sudo "$@"
}

deploy_home_for() {
  local user="$1"
  getent passwd "${user}" | cut -d: -f6
}

run_as_deploy() {
  local user="$1"
  local home="$2"
  shift 2
  [[ -n "${home}" ]] || die "deploy ユーザー ${user} の HOME が解決できません。"
  log "running as ${user} from ${home}: $*"
  # deploy_api.sh や非対話の Ruby/Bundler 確認は deploy ユーザーとして
  # 実行するが、呼び出し元の cwd が /home/sio など deploy から読めない
  # 場所だと、内部で起動される rbenv/ruby-build が戻り先を失う。ここで
  # deploy HOME へ移動してから引数配列を実行し、sudo による HOME/PATH の
  # 破壊と cwd 継承を同時に避ける。
  sudo -u "${user}" -H \
    env HOME="${home}" \
        RBENV_ROOT="${home}/.rbenv" \
        PATH="${home}/.rbenv/bin:${home}/.rbenv/shims:/usr/local/bin:/usr/bin:/bin" \
    bash -c 'set -Eeuo pipefail; cd "$HOME"; "$@"' bash "$@"
}

check_repository_access() {
  local repository="$1"
  log "checking repository access as invoking user: user=$(id -un) home=${INVOKING_HOME} repo=${repository}"
  if ! git ls-remote "${repository}" HEAD >/dev/null 2>&1; then
    printf '[%s] [%s] エラー: GitHubリポジトリへアクセスできません。\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${0##*/}" >&2
    printf '実行ユーザー: %s\n' "$(id -un)" >&2
    printf 'HOME: %s\n' "${INVOKING_HOME:-未設定}" >&2
    printf 'SSH_AUTH_SOCK: %s\n' "${SSH_AUTH_SOCK:-未設定}" >&2
    printf '対象リポジトリ: %s\n' "${repository}" >&2
    printf '通常ユーザーで次を確認してください:\n' >&2
    printf '  ssh -T git@github.com\n' >&2
    printf "  git ls-remote '%s' HEAD\n" "${repository}" >&2
    return 1
  fi
}

set_cli_value() {
  local key="$1"
  local value="$2"
  [[ "${key}" =~ ^[A-Z0-9_]+$ ]] || die "内部エラー: unsafe key ${key}"
  cli_values["${key}"]="${value}"
}

parse_bool_value() {
  local raw="$1"
  case "${raw,,}" in
    yes|y|true|1) printf 'true\n' ;;
    no|n|false|0) printf 'false\n' ;;
    *) return 1 ;;
  esac
}

while (($#)); do
  case "$1" in
    --config) CONFIG_FILE="${2:-}"; shift 2 ;;
    --rails-env-file) RAILS_ENV_INPUT_FILE="${2:-}"; RAILS_ENV_FILE_EXPLICIT=true; shift 2 ;;
    --interactive) INTERACTIVE_FLAG=true; shift ;;
    --non-interactive) NON_INTERACTIVE_FLAG=true; shift ;;
    --yes) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --overwrite-rails-env) OVERWRITE_RAILS_ENV=true; shift ;;
    --update-rails-env) UPDATE_RAILS_ENV=true; shift ;;
    --update-secrets) UPDATE_SECRETS=true; shift ;;
    --server-ip) set_cli_value SERVER_IP "${2:-}"; shift 2 ;;
    --lan-cidr) set_cli_value LAN_CIDR "${2:-}"; shift 2 ;;
    --rails-repo-url) set_cli_value RAILS_REPO_URL "${2:-}"; shift 2 ;;
    --rails-ref) set_cli_value RAILS_REF "${2:-}"; shift 2 ;;
    --deploy-user) set_cli_value DEPLOY_USER "${2:-}"; shift 2 ;;
    --deploy-group) set_cli_value DEPLOY_GROUP "${2:-}"; shift 2 ;;
    --postgres-role) set_cli_value POSTGRES_ROLE "${2:-}"; shift 2 ;;
    --postgres-database) set_cli_value POSTGRES_DATABASE "${2:-}"; shift 2 ;;
    --keep-releases) set_cli_value KEEP_RELEASES "${2:-}"; shift 2 ;;
    --enable-ufw) set_cli_value ENABLE_UFW "$(parse_bool_value "${2:-}" || die "invalid bool for --enable-ufw")"; shift 2 ;;
    --allow-ssh) set_cli_value ALLOW_SSH "$(parse_bool_value "${2:-}" || die "invalid bool for --allow-ssh")"; shift 2 ;;
    --remove-nginx-default-site) set_cli_value REMOVE_NGINX_DEFAULT_SITE "$(parse_bool_value "${2:-}" || die "invalid bool for --remove-nginx-default-site")"; shift 2 ;;
    --rails-master-key) set_cli_value RAILS_MASTER_KEY "${2:-}"; shift 2 ;;
    --secret-key-base) set_cli_value SECRET_KEY_BASE "${2:-}"; shift 2 ;;
    --database-url) set_cli_value DATABASE_URL "${2:-}"; shift 2 ;;
    --database-cache-url) set_cli_value DATABASE_CACHE_URL "${2:-}"; shift 2 ;;
    --database-queue-url) set_cli_value DATABASE_QUEUE_URL "${2:-}"; shift 2 ;;
    --database-cable-url) set_cli_value DATABASE_CABLE_URL "${2:-}"; shift 2 ;;
    --resend-api-key) set_cli_value RESEND_API_KEY "${2:-}"; shift 2 ;;
    --mail-from) set_cli_value MAIL_FROM "${2:-}"; shift 2 ;;
    --app-host) set_cli_value APP_HOST "${2:-}"; shift 2 ;;
    --frontend-origin) set_cli_value FRONTEND_ORIGIN "${2:-}"; shift 2 ;;
    --frontend-url) set_cli_value FRONTEND_URL "${2:-}"; shift 2 ;;
    --session-cookie-secure) set_cli_value SESSION_COOKIE_SECURE "$(parse_bool_value "${2:-}" || die "invalid bool for --session-cookie-secure")"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ "${INTERACTIVE_FLAG}" == true && "${NON_INTERACTIVE_FLAG}" == true ]]; then
  die "--interactive と --non-interactive は同時に指定できません。"
fi

interactive_available=false
if [[ -t 0 && -t 1 ]]; then
  interactive_available=true
fi
if [[ "${INTERACTIVE_FLAG}" == true && "${interactive_available}" != true ]]; then
  die "--interactive には stdin/stdout TTY が必要です。CI、cron、非対話 SSH では --non-interactive を使ってください。"
fi
if [[ "${NON_INTERACTIVE_FLAG}" == true ]]; then
  interactive_enabled=false
elif [[ "${INTERACTIVE_FLAG}" == true || "${interactive_available}" == true ]]; then
  interactive_enabled=true
else
  interactive_enabled=false
fi

if [[ -z "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="${REPO_ROOT}/config/local.env"
fi

require_config_key() {
  local key="$1"
  [[ "${key}" =~ ^[A-Z0-9_]+$ ]] || die "設定キーが不正です: ${key}"
}

load_key_value_file() {
  local file="$1"
  local target_name="$2"
  # shellcheck disable=SC2034
  local -n target_ref="${target_name}"
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" == *"="* ]] || die "設定ファイルの行形式が不正です: ${file}"
    local key="${line%%=*}"
    local value="${line#*=}"
    require_config_key "${key}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    fi
    # shellcheck disable=SC2034
    target_ref["${key}"]="${value}"
  done < "${file}"
}

load_key_value_file "${CONFIG_FILE}" config_values
if [[ "${RAILS_ENV_FILE_EXPLICIT}" == true ]]; then
  [[ -f "${RAILS_ENV_INPUT_FILE}" ]] || die "--rails-env-file が存在しません: ${RAILS_ENV_INPUT_FILE}"
  load_key_value_file "${RAILS_ENV_INPUT_FILE}" existing_env
elif [[ -f "${RAILS_ENV_DEST}" ]]; then
  load_key_value_file "${RAILS_ENV_DEST}" existing_env
fi

source_name_for() {
  local key="$1"
  if [[ -v "cli_values[${key}]" ]]; then
    printf 'command line\n'
  elif [[ -v "config_values[${key}]" ]]; then
    printf '%s\n' "${CONFIG_FILE}"
  elif [[ -v "existing_env[${key}]" ]]; then
    if [[ "${RAILS_ENV_FILE_EXPLICIT}" == true ]]; then
      printf '%s\n' "${RAILS_ENV_INPUT_FILE}"
    else
      printf '%s\n' "${RAILS_ENV_DEST}"
    fi
  elif [[ -v "sources[${key}]" ]]; then
    printf '%s\n' "${sources[${key}]}"
  else
    printf 'default\n'
  fi
}

set_default() {
  local key="$1"
  local value="$2"
  if [[ ! -v "values[${key}]" ]]; then
    values["${key}"]="${value}"
    sources["${key}"]="default"
  fi
}

resolve_key() {
  local key="$1"
  local default_value=""
  local has_default=false
  if (($# >= 2)); then
    default_value="$2"
    has_default=true
  fi
  if [[ -v "cli_values[${key}]" ]]; then
    values["${key}"]="${cli_values[${key}]}"
    sources["${key}"]="command line"
  elif [[ -v "config_values[${key}]" ]]; then
    values["${key}"]="${config_values[${key}]}"
    sources["${key}"]="${CONFIG_FILE}"
  elif [[ -v "existing_env[${key}]" ]]; then
    values["${key}"]="${existing_env[${key}]}"
    if [[ "${RAILS_ENV_FILE_EXPLICIT}" == true ]]; then
      sources["${key}"]="${RAILS_ENV_INPUT_FILE}"
    else
      sources["${key}"]="${RAILS_ENV_DEST}"
    fi
  elif [[ "${has_default}" == true ]]; then
    values["${key}"]="${default_value}"
    sources["${key}"]="default"
  fi
}

require_value() {
  local key="$1"
  local message="${2:-${key} が不足しています。}"
  if [[ -z "${values[${key}]:-}" ]]; then
    die "${message}"
  fi
  printf '%s\n' "${values[${key}]}"
}

print_source() {
  local key="$1"
  local src="${sources[${key}]:-missing}"
  if [[ -v "secret_key[${key}]" ]]; then
    if [[ -n "${values[${key}]:-}" ]]; then
      log "${key}: ${src} ([configured])"
    else
      log "${key}: ${src} ([not configured])"
    fi
  else
    log "${key}: ${src}"
  fi
}

prompt_with_default() {
  local key="$1"
  local prompt="$2"
  local default_value="$3"
  local input
  read -r -p "${prompt} [${default_value}]: " input
  values["${key}"]="${input:-${default_value}}"
  sources["${key}"]="interactive input"
}

prompt_bool() {
  local key="$1"
  local prompt="$2"
  local default_value="$3"
  local suffix input parsed
  if [[ "${default_value}" == true ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  while true; do
    read -r -p "${prompt} [${suffix}]: " input
    input="${input:-${default_value}}"
    if parsed="$(parse_bool_value "${input}")"; then
      values["${key}"]="${parsed}"
      sources["${key}"]="interactive input"
      return 0
    fi
    printf 'yes/y/true/1 または no/n/false/0 で入力してください。\n' >&2
  done
}

prompt_secret() {
  local key="$1"
  local prompt="$2"
  local confirm="${3:-false}"
  local first second
  while true; do
    read -r -s -p "${prompt}: " first
    printf '\n'
    if [[ "${confirm}" == true ]]; then
      read -r -s -p "Confirm ${prompt}: " second
      printf '\n'
      [[ "${first}" == "${second}" ]] || {
        printf '入力が一致しません。再入力してください。\n' >&2
        continue
      }
    fi
    values["${key}"]="${first}"
    sources["${key}"]="interactive secret input"
    return 0
  done
}

prompt_secret_key_base_mode() {
  local input
  while true; do
    cat >&2 <<'PROMPT'
SECRET_KEY_BASE is not configured. Choose:
  1. 自動生成する
  2. 手入力する
  3. Rails credentials に任せて省略する
Selection [1]:
PROMPT
    read -r input
    input="${input:-1}"
    case "${input}" in
      1)
        require_command openssl
        values[SECRET_KEY_BASE]="$(openssl rand -hex 64)"
        sources[SECRET_KEY_BASE]="generated by openssl"
        return 0
        ;;
      2)
        prompt_secret SECRET_KEY_BASE "SECRET_KEY_BASE" true
        return 0
        ;;
      3)
        values[SECRET_KEY_BASE]=""
        sources[SECRET_KEY_BASE]="interactive omitted"
        SECRET_KEY_BASE_OMITTED=true
        return 0
        ;;
      *)
        printf '1, 2, 3 のいずれかで入力してください。\n' >&2
        ;;
    esac
  done
}

url_encode() {
  local value="$1"
  local i char encoded=""
  LC_CTYPE=C
  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "${char}" in
      [a-zA-Z0-9.~_-]) encoded+="${char}" ;;
      *) printf -v encoded '%s%%%02X' "${encoded}" "'${char}" ;;
    esac
  done
  printf '%s\n' "${encoded}"
}

database_name_for_key() {
  local key="$1"
  case "${key}" in
    DATABASE_URL) printf 'mitsubachi_production\n' ;;
    DATABASE_CACHE_URL) printf 'mitsubachi_production_cache\n' ;;
    DATABASE_QUEUE_URL) printf 'mitsubachi_production_queue\n' ;;
    DATABASE_CABLE_URL) printf 'mitsubachi_production_cable\n' ;;
    *) die "内部エラー: unknown database url key ${key}" ;;
  esac
}

compose_database_url_value() {
  local host="$1"
  local port="$2"
  local role="$3"
  local password="$4"
  local db="$5"
  local encoded_user encoded_password encoded_db
  encoded_user="$(url_encode "${role}")"
  encoded_password="$(url_encode "${password}")"
  encoded_db="$(url_encode "${db}")"
  printf 'postgresql://%s:%s@%s:%s/%s\n' "${encoded_user}" "${encoded_password}" "${host}" "${port}" "${encoded_db}"
}

generate_database_urls() {
  local host port role password key db
  host="$(require_value POSTGRES_HOST "PostgreSQL host が不足しています。")"
  port="$(require_value POSTGRES_PORT "PostgreSQL port が不足しています。")"
  role="$(require_value POSTGRES_ROLE "PostgreSQL role が不足しています。")"
  password="$(require_value POSTGRES_PASSWORD "PostgreSQL password が不足しています。")"
  [[ "${host}" == "127.0.0.1" ]] || die "PostgreSQL host は Unix socket を避けるため 127.0.0.1 に固定してください。"
  for key in DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL; do
    db="$(database_name_for_key "${key}")"
    values["${key}"]="$(compose_database_url_value "${host}" "${port}" "${role}" "${password}" "${db}")"
    sources["${key}"]="generated from PostgreSQL credentials"
  done
}

prompt_database_urls() {
  prompt_with_default POSTGRES_HOST "PostgreSQL host" "127.0.0.1"
  prompt_with_default POSTGRES_PORT "PostgreSQL port" "5432"
  prompt_with_default POSTGRES_ROLE "PostgreSQL role" "${values[POSTGRES_ROLE]:-mitsubachi}"
  prompt_secret POSTGRES_PASSWORD "PostgreSQL password" true
  generate_database_urls
  unset 'values[POSTGRES_PASSWORD]'
}

resolve_key SERVER_IP "192.168.1.50"
resolve_key LAN_CIDR "192.168.1.0/24"
resolve_key RAILS_REPO_URL "git@github.com:ShioPy0101/mitsubachi-ruby.git"
resolve_key RAILS_REF "main"
resolve_key DEPLOY_USER "deploy"
resolve_key DEPLOY_GROUP "deploy"
resolve_key POSTGRES_ROLE "mitsubachi"
resolve_key POSTGRES_HOST "127.0.0.1"
resolve_key POSTGRES_PORT "5432"
resolve_key POSTGRES_DATABASE "mitsubachi_production"
resolve_key KEEP_RELEASES "5"
resolve_key ENABLE_UFW "true"
resolve_key ALLOW_SSH "true"
resolve_key REMOVE_NGINX_DEFAULT_SITE "false"

resolve_key RAILS_MASTER_KEY ""
resolve_key SECRET_KEY_BASE ""
resolve_key DATABASE_URL ""
resolve_key DATABASE_CACHE_URL ""
resolve_key DATABASE_QUEUE_URL ""
resolve_key DATABASE_CABLE_URL ""
resolve_key APP_HOST ""
resolve_key FRONTEND_ORIGIN ""
resolve_key FRONTEND_URL ""
resolve_key SESSION_COOKIE_SECURE "false"
resolve_key RESEND_API_KEY ""
resolve_key MAIL_FROM ""

set_default RAILS_ENV "production"
set_default RAILS_LOG_TO_STDOUT "true"
set_default RAILS_LOG_LEVEL "info"
set_default RAILS_SERVE_STATIC_FILES "false"
set_default FILE_STORAGE_ROOT "/mnt/external-hdd/mitsubachi/files"
set_default BULK_DOWNLOAD_TMP "/mnt/external-hdd/mitsubachi/tmp/bulk_downloads"
set_default MAX_UPLOAD_SIZE_BYTES "10737418240"
set_default RAILS_MAX_THREADS "5"
set_default WEB_CONCURRENCY "1"
set_default PORT "3001"

database_url_keys=(DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL)
if [[ -v "existing_env[DATABASE_URL]" ]] &&
   [[ ! -v "existing_env[DATABASE_CACHE_URL]" || ! -v "existing_env[DATABASE_QUEUE_URL]" || ! -v "existing_env[DATABASE_CABLE_URL]" ]] &&
   [[ "${UPDATE_SECRETS}" != true && "${OVERWRITE_RAILS_ENV}" != true ]]; then
  die "Rails production は DATABASE_URL / DATABASE_CACHE_URL / DATABASE_QUEUE_URL / DATABASE_CABLE_URL の4つが必須です。単一 DATABASE_URL だけの旧構成を検出しました。--update-secrets または --overwrite-rails-env を明示して4 URLへ更新してください。"
fi

if [[ "${interactive_enabled}" == true ]]; then
  [[ "${sources[SERVER_IP]:-}" != "default" ]] || prompt_with_default SERVER_IP "Ubuntu server IP" "${values[SERVER_IP]:-192.168.1.50}"
  [[ "${sources[LAN_CIDR]:-}" != "default" ]] || prompt_with_default LAN_CIDR "LAN CIDR" "${values[LAN_CIDR]:-192.168.1.0/24}"
  [[ "${sources[RAILS_REPO_URL]:-}" != "default" ]] || prompt_with_default RAILS_REPO_URL "Rails repository" "${values[RAILS_REPO_URL]:-git@github.com:ShioPy0101/mitsubachi-ruby.git}"
  [[ "${sources[RAILS_REF]:-}" != "default" ]] || prompt_with_default RAILS_REF "Rails ref" "${values[RAILS_REF]:-main}"
  [[ "${sources[KEEP_RELEASES]:-}" != "default" ]] || prompt_with_default KEEP_RELEASES "Release retention count" "${values[KEEP_RELEASES]:-5}"
  [[ "${sources[ENABLE_UFW]:-}" != "default" ]] || prompt_bool ENABLE_UFW "Enable UFW?" "${values[ENABLE_UFW]:-true}"
  [[ "${sources[ALLOW_SSH]:-}" != "default" ]] || prompt_bool ALLOW_SSH "Allow SSH from LAN CIDR?" "${values[ALLOW_SSH]:-true}"
  [[ "${sources[REMOVE_NGINX_DEFAULT_SITE]:-}" != "default" ]] || prompt_bool REMOVE_NGINX_DEFAULT_SITE "Remove Nginx default site?" "${values[REMOVE_NGINX_DEFAULT_SITE]:-false}"
  [[ -n "${values[RAILS_MASTER_KEY]:-}" ]] || { log "RAILS_MASTER_KEY: not configured"; prompt_secret RAILS_MASTER_KEY "RAILS_MASTER_KEY" false; }
  if [[ -z "${values[SECRET_KEY_BASE]:-}" ]]; then
    prompt_secret_key_base_mode
  fi
  if [[ -z "${values[DATABASE_URL]:-}" || -z "${values[DATABASE_CACHE_URL]:-}" || -z "${values[DATABASE_QUEUE_URL]:-}" || -z "${values[DATABASE_CABLE_URL]:-}" ]]; then
    prompt_database_urls
  fi
  [[ "${sources[SESSION_COOKIE_SECURE]:-}" != "default" ]] || prompt_bool SESSION_COOKIE_SECURE "Use insecure HTTP session cookie for LAN testing? (false means LAN HTTP)" "${values[SESSION_COOKIE_SECURE]:-false}"
fi

is_explicit_derived_value() {
  local key="$1"
  local src="${sources[${key}]:-}"
  local value="${values[${key}]:-}"
  [[ -n "${value}" ]] || return 1
  [[ "${src}" != "default" && "${src}" != "default from SERVER_IP" && -n "${src}" ]]
}

set_derived_default() {
  local key="$1"
  local value="$2"
  if ! is_explicit_derived_value "${key}"; then
    values["${key}"]="${value}"
    sources["${key}"]="default from SERVER_IP"
  fi
}

server_ip_for_derived="$(require_value SERVER_IP "SERVER_IP が不足しています。")"
set_derived_default APP_HOST "${server_ip_for_derived}"
set_derived_default FRONTEND_ORIGIN "http://${server_ip_for_derived}"
set_derived_default FRONTEND_URL "http://${server_ip_for_derived}"

missing_database_url_keys=()
for key in "${database_url_keys[@]}"; do
  [[ -n "${values[${key}]:-}" ]] || missing_database_url_keys+=("${key}")
done
if [[ -n "${values[DATABASE_URL]:-}" && ( ${#missing_database_url_keys[@]} -gt 0 ) ]]; then
  die "Rails production は DATABASE_URL / DATABASE_CACHE_URL / DATABASE_QUEUE_URL / DATABASE_CABLE_URL の4つが必須です。単一 DATABASE_URL だけの旧構成を検出しました。--interactive で再生成するか、--update-secrets と4 URLを指定してください。"
fi

required_keys=(SERVER_IP LAN_CIDR RAILS_REPO_URL RAILS_REF DEPLOY_USER DEPLOY_GROUP POSTGRES_ROLE POSTGRES_HOST POSTGRES_PORT POSTGRES_DATABASE KEEP_RELEASES ENABLE_UFW ALLOW_SSH REMOVE_NGINX_DEFAULT_SITE RAILS_MASTER_KEY DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL APP_HOST FRONTEND_ORIGIN FRONTEND_URL SESSION_COOKIE_SECURE)
for key in "${required_keys[@]}"; do
  if [[ -z "${values[${key}]:-}" ]]; then
    die "${key} が不足しています。--interactive で入力するか、--config / --rails-env-file / 明示引数で指定してください。"
  fi
done
if [[ -z "${values[SECRET_KEY_BASE]:-}" && "${SECRET_KEY_BASE_OMITTED}" != true ]]; then
  die "SECRET_KEY_BASE が不足しています。interactive では自動生成、手入力、省略を選択できます。non-interactive では明示設定してください。"
fi

server_ip="$(require_value SERVER_IP "SERVER_IP が不足しています。")"
lan_cidr="$(require_value LAN_CIDR "LAN_CIDR が不足しています。")"
rails_repo_url="$(require_value RAILS_REPO_URL "RAILS_REPO_URL が不足しています。")"
rails_ref="$(require_value RAILS_REF "RAILS_REF が不足しています。")"
deploy_user="$(require_value DEPLOY_USER "DEPLOY_USER が不足しています。")"
deploy_group="$(require_value DEPLOY_GROUP "DEPLOY_GROUP が不足しています。")"
postgres_role="$(require_value POSTGRES_ROLE "POSTGRES_ROLE が不足しています。")"
postgres_host="$(require_value POSTGRES_HOST "POSTGRES_HOST が不足しています。")"
postgres_port="$(require_value POSTGRES_PORT "POSTGRES_PORT が不足しています。")"
postgres_database="$(require_value POSTGRES_DATABASE "POSTGRES_DATABASE が不足しています。")"
keep_releases="$(require_value KEEP_RELEASES "KEEP_RELEASES が不足しています。")"
file_storage_root="$(require_value FILE_STORAGE_ROOT "FILE_STORAGE_ROOT が不足しています。")"
bulk_download_tmp="$(require_value BULK_DOWNLOAD_TMP "BULK_DOWNLOAD_TMP が不足しています。")"
max_upload_size_bytes="$(require_value MAX_UPLOAD_SIZE_BYTES "MAX_UPLOAD_SIZE_BYTES が不足しています。")"
enable_ufw="$(require_value ENABLE_UFW "ENABLE_UFW が不足しています。")"
allow_ssh="$(require_value ALLOW_SSH "ALLOW_SSH が不足しています。")"

[[ "${deploy_user}" == "deploy" ]] || die "現在の systemd/bootstrap 設計では DEPLOY_USER=deploy のみ対応しています。指定値=${deploy_user}"
[[ "${deploy_group}" == "deploy" ]] || die "現在の systemd/bootstrap 設計では DEPLOY_GROUP=deploy のみ対応しています。指定値=${deploy_group}"
[[ "${postgres_role}" == "mitsubachi" ]] || die "PostgreSQL role は mitsubachi に統一してください。指定値=${postgres_role}"
[[ "${postgres_host}" == "127.0.0.1" ]] || die "PostgreSQL host は 127.0.0.1 に固定してください。"
[[ "${postgres_port}" == "5432" ]] || die "PostgreSQL port は 5432 に固定してください。"
[[ "${postgres_database}" == "mitsubachi_production" ]] || die "primary database は mitsubachi_production に固定してください。"
private_ipv4 "${server_ip}" || die "SERVER_IP は private IPv4 である必要があります。"
cidr_contains_ipv4 "${lan_cidr}" "${server_ip}" || die "SERVER_IP は LAN_CIDR 内である必要があります。"
[[ "${lan_cidr}" != "0.0.0.0/0" ]] || die "LAN_CIDR に 0.0.0.0/0 は指定できません。"
if ! [[ "${keep_releases}" =~ ^[0-9]+$ ]] || (( keep_releases < 1 )); then
  die "KEEP_RELEASES は正の整数である必要があります。"
fi
[[ "${file_storage_root}" == "/mnt/external-hdd/mitsubachi/files" ]] || die "FILE_STORAGE_ROOT は /mnt/external-hdd/mitsubachi/files に固定してください。"
[[ "${bulk_download_tmp}" == "/mnt/external-hdd/mitsubachi/tmp/bulk_downloads" ]] || die "BULK_DOWNLOAD_TMP は /mnt/external-hdd/mitsubachi/tmp/bulk_downloads に固定してください。"
[[ "${max_upload_size_bytes}" == "10737418240" ]] || die "MAX_UPLOAD_SIZE_BYTES は 10737418240 にしてください。"
if [[ "${enable_ufw}" == true && "${allow_ssh}" != true ]]; then
  die "ENABLE_UFW=true の場合は、SSH 締め出し防止のため ALLOW_SSH=true が必要です。"
fi

validate_derived_default() {
  local key="$1"
  local expected="$2"
  if ! is_explicit_derived_value "${key}" && [[ "${values[${key}]:-}" != "${expected}" ]]; then
    die "${key} は明示指定されていないため ${expected} である必要があります。現在値=${values[${key}]:-<empty>}"
  fi
}

validate_derived_default APP_HOST "${server_ip}"
validate_derived_default FRONTEND_ORIGIN "http://${server_ip}"
validate_derived_default FRONTEND_URL "http://${server_ip}"

log "invoking user: ${INVOKING_USER}"
log "invoking home: ${INVOKING_HOME}"
log "deploy user: ${deploy_user}"
log "deploy group: ${deploy_group}"
if [[ "${DRY_RUN}" != true ]]; then
  log "checking sudo credentials for root-only installation steps"
  sudo -v || die "sudo を利用できないため停止します。apt、/etc、/var、/mnt、systemd、Nginx、UFW の設定に sudo が必要です。"
  log "checking external HDD mount before installation starts"
  mountpoint -q "${EXTERNAL_HDD}" || die "${EXTERNAL_HDD} は mount point ではありません。外付け HDD 未 mount のまま install を開始しません。"
  require_command git
  check_repository_access "${rails_repo_url}" || die "Rails repository access check failed before privileged installation steps."
fi

for key in "${!values[@]}"; do
  print_source "${key}"
done | sort >&2

summary_secret_state() {
  local key="$1"
  if [[ -n "${values[${key}]:-}" ]]; then
    printf '[configured]'
  else
    printf '[not configured]'
  fi
}

cat <<SUMMARY
Installation summary
--------------------
Server IP:          ${server_ip}
LAN CIDR:           ${lan_cidr}
Rails repository:   ${rails_repo_url}
Rails ref:          ${rails_ref}
Deploy user:        ${deploy_user}
Deploy group:       ${deploy_group}
App root:           /var/www/mitsubachi
Storage root:       ${file_storage_root}
Bulk ZIP tmp:       ${bulk_download_tmp}
App host:           ${values[APP_HOST]:-}
Frontend origin:    ${values[FRONTEND_ORIGIN]:-}
Frontend URL:       ${values[FRONTEND_URL]:-}
PostgreSQL role:    ${postgres_role}
PostgreSQL host:    ${postgres_host}
PostgreSQL port:    ${postgres_port}
PostgreSQL DBs:     mitsubachi_production, mitsubachi_production_cache, mitsubachi_production_queue, mitsubachi_production_cable
Enable UFW:         ${enable_ufw}
Allow SSH:          ${allow_ssh}
Rails env file:     ${RAILS_ENV_DEST}
Rails master key:   $(summary_secret_state RAILS_MASTER_KEY)
Secret key base:    $(summary_secret_state SECRET_KEY_BASE)
Database URL:       $(summary_secret_state DATABASE_URL)
Cache DB URL:       $(summary_secret_state DATABASE_CACHE_URL)
Queue DB URL:       $(summary_secret_state DATABASE_QUEUE_URL)
Cable DB URL:       $(summary_secret_state DATABASE_CABLE_URL)
Resend API key:     $(summary_secret_state RESEND_API_KEY)
SUMMARY

if [[ "${YES}" != true && "${interactive_enabled}" == true ]]; then
  proceed=false
  prompt_bool proceed "Proceed with installation?" "false"
  [[ "${values[proceed]:-}" == true ]] || die "利用者が中止しました。変更は行っていません。"
elif [[ "${YES}" != true && "${interactive_enabled}" != true ]]; then
  die "--yes が指定されていないため、非対話実行では開始しません。"
fi

write_non_secret_config=false
if [[ ! -f "${CONFIG_FILE}" && "${interactive_enabled}" == true ]]; then
  prompt_bool SAVE_CONFIG "Save non-secret configuration to ${CONFIG_FILE}?" "true"
  write_non_secret_config="${values[SAVE_CONFIG]:-false}"
fi

write_config_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"
  chmod 0600 "${tmp}"
  {
    printf 'SERVER_IP=%s\n' "${server_ip}"
    printf 'LAN_CIDR=%s\n' "${lan_cidr}"
    printf 'RAILS_REPO_URL=%s\n' "${rails_repo_url}"
    printf 'RAILS_REF=%s\n' "${rails_ref}"
    printf 'DEPLOY_USER=%s\n' "${deploy_user}"
    printf 'DEPLOY_GROUP=%s\n' "${deploy_group}"
    printf 'POSTGRES_ROLE=%s\n' "${postgres_role}"
    printf 'POSTGRES_HOST=%s\n' "${postgres_host}"
    printf 'POSTGRES_PORT=%s\n' "${postgres_port}"
    printf 'POSTGRES_DATABASE=%s\n' "${postgres_database}"
    printf 'KEEP_RELEASES=%s\n' "${keep_releases}"
    printf 'ENABLE_UFW=%s\n' "${enable_ufw}"
    printf 'ALLOW_SSH=%s\n' "${allow_ssh}"
    printf 'REMOVE_NGINX_DEFAULT_SITE=%s\n' "${values[REMOVE_NGINX_DEFAULT_SITE]:-false}"
  } > "${tmp}"
  install -d -m 0755 -- "$(dirname -- "${target}")"
  install -m 0600 -- "${tmp}" "${target}"
  rm -f -- "${tmp}"
}

compose_rails_env() {
  local output="$1"
  local key existing_value new_value is_secret
  declare -A written
  if [[ -f "${RAILS_ENV_DEST}" && "${OVERWRITE_RAILS_ENV}" != true ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      if [[ "${line}" == *"="* && ! "${line}" =~ ^[[:space:]]*# ]]; then
        key="${line%%=*}"
        if [[ -v "values[${key}]" ]]; then
          existing_value="${existing_env[${key}]:-${line#*=}}"
          new_value="${values[${key}]}"
          is_secret=false
          [[ -v "secret_key[${key}]" ]] && is_secret=true
          if [[ "${existing_value}" != "${new_value}" ]]; then
            if [[ "${is_secret}" == true && "${UPDATE_SECRETS}" == true ]]; then
              printf '%s=%s\n' "${key}" "${new_value}" >> "${output}"
            elif [[ "${is_secret}" != true && "${UPDATE_RAILS_ENV}" == true ]]; then
              printf '%s=%s\n' "${key}" "${new_value}" >> "${output}"
            else
              printf '%s\n' "${line}" >> "${output}"
            fi
          else
            printf '%s\n' "${line}" >> "${output}"
          fi
          written["${key}"]=true
        else
          printf '%s\n' "${line}" >> "${output}"
        fi
      else
        printf '%s\n' "${line}" >> "${output}"
      fi
    done < "${RAILS_ENV_DEST}"
  fi
  for key in RAILS_ENV RAILS_LOG_TO_STDOUT RAILS_LOG_LEVEL RAILS_SERVE_STATIC_FILES RAILS_MASTER_KEY SECRET_KEY_BASE DATABASE_URL DATABASE_CACHE_URL DATABASE_QUEUE_URL DATABASE_CABLE_URL FILE_STORAGE_ROOT BULK_DOWNLOAD_TMP MAX_UPLOAD_SIZE_BYTES APP_HOST FRONTEND_ORIGIN FRONTEND_URL SESSION_COOKIE_SECURE RAILS_MAX_THREADS WEB_CONCURRENCY PORT RESEND_API_KEY MAIL_FROM; do
    [[ -v "written[${key}]" ]] && continue
    printf '%s=%s\n' "${key}" "${values[${key}]:-}" >> "${output}"
  done
}

install_rails_env_file() {
  local tmp
  tmp="$(mktemp)"
  chmod 0600 "${tmp}"
  compose_rails_env "${tmp}"
  if [[ -f "${RAILS_ENV_DEST}" && "${OVERWRITE_RAILS_ENV}" == true ]]; then
    sudo_cmd cp -a -- "${RAILS_ENV_DEST}" "${RAILS_ENV_DEST}.backup.$(date -u '+%Y%m%dT%H%M%SZ')"
  fi
  sudo_cmd install -d -o root -g "${deploy_user}" -m 0750 -- "$(dirname -- "${RAILS_ENV_DEST}")"
  sudo_cmd install -o root -g "${deploy_user}" -m 0640 -- "${tmp}" "${RAILS_ENV_DEST}"
  rm -f -- "${tmp}"
}

ensure_deploy_account() {
  if ! getent group "${deploy_group}" >/dev/null; then
    log "creating deploy group before owner/group dependent files: ${deploy_group}"
    sudo_cmd groupadd --system "${deploy_group}" || die "deploy group could not be created: ${deploy_group}"
  else
    log "deploy group already exists: ${deploy_group}"
  fi

  if ! id "${deploy_user}" >/dev/null 2>&1; then
    log "creating deploy user before owner/group dependent files: ${deploy_user}"
    sudo_cmd useradd \
      --system \
      --gid "${deploy_group}" \
      --create-home \
      --home-dir "/home/${deploy_user}" \
      --shell /bin/bash \
      "${deploy_user}" || die "deploy user could not be created: ${deploy_user}"
  else
    log "deploy user already exists: ${deploy_user}"
  fi

  getent group "${deploy_group}" >/dev/null || die "deploy group could not be created: ${deploy_group}"
  id "${deploy_user}" >/dev/null 2>&1 || die "deploy user could not be created: ${deploy_user}"
}

if [[ "${DRY_RUN}" == true ]]; then
  log "[DRY-RUN] create system group if missing: ${deploy_group}"
  log "[DRY-RUN] create system user if missing: ${deploy_user}"
  log "[DRY-RUN] create directory: /etc/mitsubachi owner=root group=${deploy_group} mode=0750"
  log "[DRY-RUN] install rails env: ${RAILS_ENV_DEST} owner=root group=${deploy_group} mode=0640"
  log "[DRY-RUN] run bootstrap_ubuntu.sh as root after rails.env placement"
  log "dry-run のため、設定ファイル作成、bootstrap、LAN 設定、deploy は実行しません。"
  exit 0
fi

require_command install

if [[ "${write_non_secret_config}" == true ]]; then
  write_config_file "${CONFIG_FILE}"
fi

ensure_deploy_account

if [[ -f "${RAILS_ENV_DEST}" && "${OVERWRITE_RAILS_ENV}" != true ]]; then
  log "既存 rails.env を保持し、不足キーだけ追加します。既存値の変更には --update-rails-env または --update-secrets が必要です。"
fi
install_rails_env_file

bootstrap_args=(--install-nginx-config --install-systemd-unit)
if [[ -n "${postgres_role}" && -n "${postgres_database}" ]]; then
  bootstrap_args+=(--create-db-role "${postgres_role}" --create-db "${postgres_database}")
fi
if [[ "${values[REMOVE_NGINX_DEFAULT_SITE]:-false}" == true ]]; then
  bootstrap_args+=(--remove-default-site)
fi
log "running bootstrap_ubuntu.sh as root; it creates system users, directories, packages, Nginx, and systemd"
sudo_cmd "${SCRIPT_DIR}/bootstrap_ubuntu.sh" "${bootstrap_args[@]}"

deploy_home="$(deploy_home_for "${deploy_user}")"
[[ -n "${deploy_home}" ]] || die "deploy ユーザー ${deploy_user} が存在しない、または HOME を解決できません。bootstrap が失敗していないか確認してください。"
log "deploy home: ${deploy_home}"

network_args=(--lan-cidr "${lan_cidr}" --server-ip "${server_ip}" --install-nginx-config)
if [[ "${enable_ufw}" == true ]]; then network_args+=(--enable-ufw); fi
if [[ "${allow_ssh}" == true ]]; then network_args+=(--allow-ssh); fi
if [[ "${values[REMOVE_NGINX_DEFAULT_SITE]:-false}" == true ]]; then network_args+=(--remove-default-site); fi
log "running configure_local_network.sh as root for Nginx/UFW changes"
sudo_cmd "${SCRIPT_DIR}/configure_local_network.sh" "${network_args[@]}"

log "checking deploy user Ruby/Bundler visibility in a non-interactive rbenv environment"
run_as_deploy "${deploy_user}" "${deploy_home}" bash -lc 'command -v ruby >/dev/null && ruby -v >/dev/null && command -v bundle >/dev/null && bundle -v >/dev/null' \
  || die "deploy ユーザー ${deploy_user} で ruby/bundle を実行できません。${deploy_home}/.rbenv の導入状態と PATH を確認してください。"

run_as_deploy "${deploy_user}" "${deploy_home}" "${SCRIPT_DIR}/deploy_api.sh" \
  --repo-url "${rails_repo_url}" \
  --ref "${rails_ref}" \
  --keep-releases "${keep_releases}"

log "対話式 LAN install が完了しました。"
