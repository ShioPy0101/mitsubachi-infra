#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/backup_postgres.sh [options]

Options:
  --env-file PATH          Environment file. Default: /etc/mitsubachi/rails.env.
  --retention-days DAYS    Delete backups older than DAYS. Default: 14.
  --min-free-kb KB         Required free space before starting. Default: 1048576.
  --help                   Show this help.
USAGE
}

RETENTION_DAYS=14
MIN_FREE_KB=1048576

while (($#)); do
  case "$1" in
    --env-file) RAILS_ENV_FILE="${2:-}"; shift 2 ;;
    --retention-days) RETENTION_DAYS="${2:-}"; shift 2 ;;
    --min-free-kb) MIN_FREE_KB="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command pg_dump mktemp find ruby
[[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] || die "--retention-days must be numeric"
[[ "${MIN_FREE_KB}" =~ ^[0-9]+$ ]] || die "--min-free-kb must be numeric"

with_lock "backup-postgres"
set_stage "preflight"
# PostgreSQL backup は pg_dump custom format を一時ファイルへ出力し、
# 成功後だけ atomic rename する。途中失敗した dump を正式な世代として
# 残さないことを重視する。DATABASE_URL を pg_dump の引数へ直接渡すと
# password が process list に見える可能性があるため、Ruby 標準ライブラリで
# URL を parse し、一時 PGPASSFILE と個別接続オプションへ変換する。
log "PostgreSQL backup を開始します。出力先=${POSTGRES_BACKUP_DIR}"
require_mountpoint "${EXTERNAL_HDD}"
require_writable_dir "${POSTGRES_BACKUP_DIR}"
require_filesystem_rw "${POSTGRES_BACKUP_DIR}"
require_disk_free_kb "${POSTGRES_BACKUP_DIR}" "${MIN_FREE_KB}"
load_systemd_env_file "${RAILS_ENV_FILE}"
[[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL is missing in ${RAILS_ENV_FILE}"

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
tmp_file="$(mktemp "${POSTGRES_BACKUP_DIR}/postgres-${timestamp}.XXXXXX.tmp")"
final_file="${POSTGRES_BACKUP_DIR}/postgres-${timestamp}.dump"
conn_file="$(mktemp)"
pgpass_file="$(mktemp)"
cleanup() {
  [[ -f "${tmp_file}" ]] && rm -f -- "${tmp_file}"
  [[ -f "${conn_file}" ]] && rm -f -- "${conn_file}"
  [[ -f "${pgpass_file}" ]] && rm -f -- "${pgpass_file}"
}
trap cleanup EXIT
chmod 0600 "${tmp_file}"
chmod 0600 "${conn_file}" "${pgpass_file}"

DATABASE_URL_FOR_PARSE="${DATABASE_URL}" ruby -ruri -e '
  raw = ENV.fetch("DATABASE_URL_FOR_PARSE")
  uri = URI.parse(raw)
  unless ["postgres", "postgresql"].include?(uri.scheme)
    raise "DATABASE_URL must use postgres or postgresql scheme"
  end
  user = URI.decode_www_form_component(uri.user || "")
  password = URI.decode_www_form_component(uri.password || "")
  host = uri.host || "localhost"
  port = uri.port || 5432
  db = (uri.path || "").sub(%r{\A/}, "")
  raise "DATABASE_URL database name is empty" if db.empty?
  puts host
  puts port
  puts user
  puts password
  puts db
' > "${conn_file}"
unset DATABASE_URL DATABASE_URL_FOR_PARSE

mapfile -t conn < "${conn_file}"
db_host="${conn[0]}"
db_port="${conn[1]}"
db_user="${conn[2]}"
db_password="${conn[3]}"
db_name="${conn[4]}"
[[ -n "${db_user}" ]] || die "DATABASE_URL user is empty"
printf '%s:%s:%s:%s:%s\n' "${db_host}" "${db_port}" "${db_name}" "${db_user}" "${db_password}" > "${pgpass_file}"

set_stage "pg_dump"
log "pg_dump --format=custom を一時ファイルへ出力します。DB password と DATABASE_URL は表示しません。"
PGPASSFILE="${pgpass_file}" pg_dump \
  --format=custom \
  --file="${tmp_file}" \
  --host="${db_host}" \
  --port="${db_port}" \
  --username="${db_user}" \
  --dbname="${db_name}"
mv -f -- "${tmp_file}" "${final_file}"
chmod 0600 "${final_file}"

set_stage "retention"
if (( RETENTION_DAYS > 0 )); then
  log "retention を適用します。${RETENTION_DAYS} 日より古い PostgreSQL backup を削除します。"
  find "${POSTGRES_BACKUP_DIR}" -maxdepth 1 -type f -name 'postgres-*.dump' -mtime "+${RETENTION_DAYS}" -delete
fi
log "PostgreSQL backup が完了しました: ${final_file}"
