#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/backup_storage.sh [options]

Options:
  --retention-days DAYS    Delete backups older than DAYS. Default: 14.
  --min-free-kb KB         Required free space before starting. Default: 1048576.
  --help                   Show this help.
USAGE
}

RETENTION_DAYS=14
MIN_FREE_KB=1048576

while (($#)); do
  case "$1" in
    --retention-days) RETENTION_DAYS="${2:-}"; shift 2 ;;
    --min-free-kb) MIN_FREE_KB="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command tar mktemp find du awk
[[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]] || die "--retention-days must be numeric"
[[ "${MIN_FREE_KB}" =~ ^[0-9]+$ ]] || die "--min-free-kb must be numeric"

with_lock "backup-storage"
set_stage "preflight"
# storage backup は同じ外付け HDD 上の backups/storage へ tar を作る。
# これは誤削除や論理破損から戻すための補助であり、HDD 自体の故障には
# 耐えない。README でも別媒体 backup の必要性を明示する。
log "ファイルストレージ backup を開始します。source=${FILE_STORAGE_ROOT} destination=${STORAGE_BACKUP_DIR}"
require_mountpoint "${EXTERNAL_HDD}"
require_readable_dir "${FILE_STORAGE_ROOT}"
require_writable_dir "${STORAGE_BACKUP_DIR}"
require_filesystem_rw "${STORAGE_BACKUP_DIR}"
source_real="$(readlink -f -- "${FILE_STORAGE_ROOT}")"
dest_real="$(readlink -f -- "${STORAGE_BACKUP_DIR}")"
[[ "${dest_real}" != "${source_real}" ]] || die "storage backup destination must not equal source"
[[ "${dest_real}" != "${source_real}/"* ]] || die "storage backup destination must not be inside source"
required_kb="$(du -sk -- "${FILE_STORAGE_ROOT}" | awk '{print $1}')"
(( required_kb < MIN_FREE_KB )) && required_kb="${MIN_FREE_KB}"
require_disk_free_kb "${STORAGE_BACKUP_DIR}" "${required_kb}"

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
tmp_file="$(mktemp "${STORAGE_BACKUP_DIR}/storage-${timestamp}.XXXXXX.tmp")"
final_file="${STORAGE_BACKUP_DIR}/storage-${timestamp}.tar.gz"
cleanup() {
  [[ -f "${tmp_file}" ]] && rm -f -- "${tmp_file}"
}
trap cleanup EXIT
chmod 0600 "${tmp_file}"

set_stage "tar"
log "storage tar archive を一時ファイルへ作成します。backup destination 自身は source 外なので再帰混入しません。"
tar -C "${FILE_STORAGE_ROOT}" -czf "${tmp_file}" .
mv -f -- "${tmp_file}" "${final_file}"
chmod 0600 "${final_file}"

set_stage "retention"
if (( RETENTION_DAYS > 0 )); then
  log "retention を適用します。${RETENTION_DAYS} 日より古い storage backup を削除します。"
  find "${STORAGE_BACKUP_DIR}" -maxdepth 1 -type f -name 'storage-*.tar.gz' -mtime "+${RETENTION_DAYS}" -delete
fi
log "ファイルストレージ backup が完了しました: ${final_file}"
