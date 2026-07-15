#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: sudo scripts/install_local.sh [options]

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
    --postgres-role) set_cli_value POSTGRES_ROLE "${2:-}"; shift 2 ;;
    --postgres-database) set_cli_value POSTGRES_DATABASE "${2:-}"; shift 2 ;;
    --keep-releases) set_cli_value KEEP_RELEASES "${2:-}"; shift 2 ;;
    --enable-ufw) set_cli_value ENABLE_UFW "$(parse_bool_value "${2:-}" || die "invalid bool for --enable-ufw")"; shift 2 ;;
    --allow-ssh) set_cli_value ALLOW_SSH "$(parse_bool_value "${2:-}" || die "invalid bool for --allow-ssh")"; shift 2 ;;
    --remove-nginx-default-site) set_cli_value REMOVE_NGINX_DEFAULT_SITE "$(parse_bool_value "${2:-}" || die "invalid bool for --remove-nginx-default-site")"; shift 2 ;;
    --rails-master-key) set_cli_value RAILS_MASTER_KEY "${2:-}"; shift 2 ;;
    --secret-key-base) set_cli_value SECRET_KEY_BASE "${2:-}"; shift 2 ;;
    --database-url) set_cli_value DATABASE_URL "${2:-}"; shift 2 ;;
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
  local default_value="${2-}"
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
  elif [[ -n "${default_value}" ]]; then
    values["${key}"]="${default_value}"
    sources["${key}"]="default"
  fi
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
  VALUE_TO_ENCODE="${value}" ruby -rcgi -e 'print CGI.escape(ENV.fetch("VALUE_TO_ENCODE"))'
}

prompt_database_url() {
  local host port role db password encoded_user encoded_password encoded_db
  prompt_with_default POSTGRES_HOST "PostgreSQL host" "127.0.0.1"
  prompt_with_default POSTGRES_PORT "PostgreSQL port" "5432"
  prompt_with_default POSTGRES_ROLE "PostgreSQL role" "${values[POSTGRES_ROLE]:-mitsubachi}"
  prompt_with_default POSTGRES_DATABASE "PostgreSQL database" "${values[POSTGRES_DATABASE]:-mitsubachi_production}"
  prompt_secret POSTGRES_PASSWORD "PostgreSQL password" true
  host="${values[POSTGRES_HOST]}"
  port="${values[POSTGRES_PORT]}"
  role="${values[POSTGRES_ROLE]}"
  db="${values[POSTGRES_DATABASE]}"
  password="${values[POSTGRES_PASSWORD]}"
  encoded_user="$(url_encode "${role}")"
  encoded_password="$(url_encode "${password}")"
  encoded_db="$(url_encode "${db}")"
  values[DATABASE_URL]="postgresql://${encoded_user}:${encoded_password}@${host}:${port}/${encoded_db}"
  sources[DATABASE_URL]="interactive secret input"
  unset 'values[POSTGRES_PASSWORD]'
}

resolve_key SERVER_IP "192.168.1.50"
resolve_key LAN_CIDR "192.168.1.0/24"
resolve_key RAILS_REPO_URL "git@github.com:ShioPy0101/mitsubachi-ruby.git"
resolve_key RAILS_REF "main"
resolve_key DEPLOY_USER "deploy"
resolve_key POSTGRES_ROLE "mitsubachi"
resolve_key POSTGRES_DATABASE "mitsubachi_production"
resolve_key KEEP_RELEASES "5"
resolve_key ENABLE_UFW "true"
resolve_key ALLOW_SSH "true"
resolve_key REMOVE_NGINX_DEFAULT_SITE "false"

resolve_key RAILS_MASTER_KEY ""
resolve_key SECRET_KEY_BASE ""
resolve_key DATABASE_URL ""
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

if [[ -z "${values[APP_HOST]}" ]]; then values[APP_HOST]="${values[SERVER_IP]}"; sources[APP_HOST]="default from SERVER_IP"; fi
if [[ -z "${values[FRONTEND_ORIGIN]}" ]]; then values[FRONTEND_ORIGIN]="http://${values[SERVER_IP]}"; sources[FRONTEND_ORIGIN]="default from SERVER_IP"; fi
if [[ -z "${values[FRONTEND_URL]}" ]]; then values[FRONTEND_URL]="http://${values[SERVER_IP]}"; sources[FRONTEND_URL]="default from SERVER_IP"; fi

if [[ "${interactive_enabled}" == true ]]; then
  [[ "${sources[SERVER_IP]:-}" != "default" ]] || prompt_with_default SERVER_IP "Ubuntu server IP" "${values[SERVER_IP]}"
  [[ "${sources[LAN_CIDR]:-}" != "default" ]] || prompt_with_default LAN_CIDR "LAN CIDR" "${values[LAN_CIDR]}"
  [[ "${sources[RAILS_REPO_URL]:-}" != "default" ]] || prompt_with_default RAILS_REPO_URL "Rails repository" "${values[RAILS_REPO_URL]}"
  [[ "${sources[RAILS_REF]:-}" != "default" ]] || prompt_with_default RAILS_REF "Rails ref" "${values[RAILS_REF]}"
  [[ "${sources[KEEP_RELEASES]:-}" != "default" ]] || prompt_with_default KEEP_RELEASES "Release retention count" "${values[KEEP_RELEASES]}"
  [[ "${sources[ENABLE_UFW]:-}" != "default" ]] || prompt_bool ENABLE_UFW "Enable UFW?" "${values[ENABLE_UFW]}"
  [[ "${sources[ALLOW_SSH]:-}" != "default" ]] || prompt_bool ALLOW_SSH "Allow SSH from LAN CIDR?" "${values[ALLOW_SSH]}"
  [[ "${sources[REMOVE_NGINX_DEFAULT_SITE]:-}" != "default" ]] || prompt_bool REMOVE_NGINX_DEFAULT_SITE "Remove Nginx default site?" "${values[REMOVE_NGINX_DEFAULT_SITE]}"
  [[ -n "${values[RAILS_MASTER_KEY]}" ]] || { log "RAILS_MASTER_KEY: not configured"; prompt_secret RAILS_MASTER_KEY "RAILS_MASTER_KEY" false; }
  if [[ -z "${values[SECRET_KEY_BASE]}" ]]; then
    prompt_secret_key_base_mode
  fi
  [[ -n "${values[DATABASE_URL]}" ]] || prompt_database_url
  [[ "${sources[SESSION_COOKIE_SECURE]:-}" != "default" ]] || prompt_bool SESSION_COOKIE_SECURE "Use insecure HTTP session cookie for LAN testing? (false means LAN HTTP)" "${values[SESSION_COOKIE_SECURE]}"
fi

required_keys=(SERVER_IP LAN_CIDR RAILS_REPO_URL RAILS_REF DEPLOY_USER POSTGRES_ROLE POSTGRES_DATABASE KEEP_RELEASES ENABLE_UFW ALLOW_SSH REMOVE_NGINX_DEFAULT_SITE RAILS_MASTER_KEY DATABASE_URL APP_HOST FRONTEND_ORIGIN FRONTEND_URL SESSION_COOKIE_SECURE)
for key in "${required_keys[@]}"; do
  if [[ -z "${values[${key}]:-}" ]]; then
    die "${key} が不足しています。--interactive で入力するか、--config / --rails-env-file / 明示引数で指定してください。"
  fi
done
if [[ -z "${values[SECRET_KEY_BASE]:-}" && "${SECRET_KEY_BASE_OMITTED}" != true ]]; then
  die "SECRET_KEY_BASE が不足しています。interactive では自動生成、手入力、省略を選択できます。non-interactive では明示設定してください。"
fi

private_ipv4 "${values[SERVER_IP]}" || die "SERVER_IP は private IPv4 である必要があります。"
cidr_contains_ipv4 "${values[LAN_CIDR]}" "${values[SERVER_IP]}" || die "SERVER_IP は LAN_CIDR 内である必要があります。"
[[ "${values[LAN_CIDR]}" != "0.0.0.0/0" ]] || die "LAN_CIDR に 0.0.0.0/0 は指定できません。"
if ! [[ "${values[KEEP_RELEASES]}" =~ ^[0-9]+$ ]] || (( values[KEEP_RELEASES] < 1 )); then
  die "KEEP_RELEASES は正の整数である必要があります。"
fi
[[ "${values[FILE_STORAGE_ROOT]}" == "/mnt/external-hdd/mitsubachi/files" ]] || die "FILE_STORAGE_ROOT は /mnt/external-hdd/mitsubachi/files に固定してください。"
[[ "${values[BULK_DOWNLOAD_TMP]}" == "/mnt/external-hdd/mitsubachi/tmp/bulk_downloads" ]] || die "BULK_DOWNLOAD_TMP は /mnt/external-hdd/mitsubachi/tmp/bulk_downloads に固定してください。"
[[ "${values[MAX_UPLOAD_SIZE_BYTES]}" == "10737418240" ]] || die "MAX_UPLOAD_SIZE_BYTES は 10737418240 にしてください。"
if [[ "${values[ENABLE_UFW]}" == true && "${values[ALLOW_SSH]}" != true ]]; then
  die "ENABLE_UFW=true の場合は、SSH 締め出し防止のため ALLOW_SSH=true が必要です。"
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
Server IP:          ${values[SERVER_IP]}
LAN CIDR:           ${values[LAN_CIDR]}
Rails repository:   ${values[RAILS_REPO_URL]}
Rails ref:          ${values[RAILS_REF]}
Deploy user:        ${values[DEPLOY_USER]}
App root:           /var/www/mitsubachi
Storage root:       ${values[FILE_STORAGE_ROOT]}
Bulk ZIP tmp:       ${values[BULK_DOWNLOAD_TMP]}
PostgreSQL role:    ${values[POSTGRES_ROLE]}
PostgreSQL DB:      ${values[POSTGRES_DATABASE]}
Enable UFW:         ${values[ENABLE_UFW]}
Allow SSH:          ${values[ALLOW_SSH]}
Rails env file:     ${RAILS_ENV_DEST}
Rails master key:   $(summary_secret_state RAILS_MASTER_KEY)
Secret key base:    $(summary_secret_state SECRET_KEY_BASE)
Database URL:       $(summary_secret_state DATABASE_URL)
Resend API key:     $(summary_secret_state RESEND_API_KEY)
SUMMARY

if [[ "${YES}" != true && "${interactive_enabled}" == true ]]; then
  proceed=false
  prompt_bool proceed "Proceed with installation?" "false"
  [[ "${values[proceed]}" == true ]] || die "利用者が中止しました。変更は行っていません。"
elif [[ "${YES}" != true && "${interactive_enabled}" != true ]]; then
  die "--yes が指定されていないため、非対話実行では開始しません。"
fi

write_non_secret_config=false
if [[ ! -f "${CONFIG_FILE}" && "${interactive_enabled}" == true ]]; then
  prompt_bool SAVE_CONFIG "Save non-secret configuration to ${CONFIG_FILE}?" "true"
  write_non_secret_config="${values[SAVE_CONFIG]}"
fi

write_config_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"
  chmod 0600 "${tmp}"
  {
    printf 'SERVER_IP=%s\n' "${values[SERVER_IP]}"
    printf 'LAN_CIDR=%s\n' "${values[LAN_CIDR]}"
    printf 'RAILS_REPO_URL=%s\n' "${values[RAILS_REPO_URL]}"
    printf 'RAILS_REF=%s\n' "${values[RAILS_REF]}"
    printf 'DEPLOY_USER=%s\n' "${values[DEPLOY_USER]}"
    printf 'POSTGRES_ROLE=%s\n' "${values[POSTGRES_ROLE]}"
    printf 'POSTGRES_DATABASE=%s\n' "${values[POSTGRES_DATABASE]}"
    printf 'KEEP_RELEASES=%s\n' "${values[KEEP_RELEASES]}"
    printf 'ENABLE_UFW=%s\n' "${values[ENABLE_UFW]}"
    printf 'ALLOW_SSH=%s\n' "${values[ALLOW_SSH]}"
    printf 'REMOVE_NGINX_DEFAULT_SITE=%s\n' "${values[REMOVE_NGINX_DEFAULT_SITE]}"
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
  for key in RAILS_ENV RAILS_LOG_TO_STDOUT RAILS_LOG_LEVEL RAILS_SERVE_STATIC_FILES RAILS_MASTER_KEY SECRET_KEY_BASE DATABASE_URL FILE_STORAGE_ROOT BULK_DOWNLOAD_TMP MAX_UPLOAD_SIZE_BYTES APP_HOST FRONTEND_ORIGIN FRONTEND_URL SESSION_COOKIE_SECURE RAILS_MAX_THREADS WEB_CONCURRENCY PORT RESEND_API_KEY MAIL_FROM; do
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
    backup_if_exists "${RAILS_ENV_DEST}"
  fi
  install -d -o root -g "${values[DEPLOY_USER]}" -m 0750 -- "$(dirname -- "${RAILS_ENV_DEST}")"
  install -o root -g "${values[DEPLOY_USER]}" -m 0640 -- "${tmp}" "${RAILS_ENV_DEST}"
  rm -f -- "${tmp}"
}

if [[ "${DRY_RUN}" == true ]]; then
  log "dry-run のため、設定ファイル作成、bootstrap、LAN 設定、deploy は実行しません。"
  exit 0
fi

require_root
require_command install

if [[ "${write_non_secret_config}" == true ]]; then
  write_config_file "${CONFIG_FILE}"
fi

if [[ -f "${RAILS_ENV_DEST}" && "${OVERWRITE_RAILS_ENV}" != true ]]; then
  log "既存 rails.env を保持し、不足キーだけ追加します。既存値の変更には --update-rails-env または --update-secrets が必要です。"
fi
install_rails_env_file

bootstrap_args=(--app-repo "${values[RAILS_REPO_URL]}" --install-nginx-config --install-systemd-unit)
if [[ "${values[REMOVE_NGINX_DEFAULT_SITE]}" == true ]]; then
  bootstrap_args+=(--remove-default-site)
fi
"${SCRIPT_DIR}/bootstrap_ubuntu.sh" "${bootstrap_args[@]}"

network_args=(--lan-cidr "${values[LAN_CIDR]}" --server-ip "${values[SERVER_IP]}" --install-nginx-config)
if [[ "${values[ENABLE_UFW]}" == true ]]; then network_args+=(--enable-ufw); fi
if [[ "${values[ALLOW_SSH]}" == true ]]; then network_args+=(--allow-ssh); fi
if [[ "${values[REMOVE_NGINX_DEFAULT_SITE]}" == true ]]; then network_args+=(--remove-default-site); fi
"${SCRIPT_DIR}/configure_local_network.sh" "${network_args[@]}"

sudo -u "${values[DEPLOY_USER]}" "${SCRIPT_DIR}/deploy_api.sh" \
  --repo-url "${values[RAILS_REPO_URL]}" \
  --ref "${values[RAILS_REF]}" \
  --keep-releases "${values[KEEP_RELEASES]}"

log "対話式 LAN install が完了しました。"
