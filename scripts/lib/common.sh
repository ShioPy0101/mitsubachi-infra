#!/usr/bin/env bash
set -Eeuo pipefail

# この共通ライブラリは、Ubuntu サーバー上で Infra リポジトリがどこへ
# clone されても同じ動作になるように、BASH_SOURCE からリポジトリルートを
# 解決する。運用者が /home/deploy、/opt/src、任意の作業ディレクトリの
# どこから実行しても、Nginx 設定や systemd unit のコピー元を取り違えない
# ことを優先している。
COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${COMMON_DIR}/../.." && pwd)"

APP_ROOT="${APP_ROOT:-/var/www/mitsubachi}"
REPO_CACHE="${REPO_CACHE:-${APP_ROOT}/repo}"
RELEASE_ROOT="${RELEASE_ROOT:-${APP_ROOT}/releases}"
CURRENT_LINK="${CURRENT_LINK:-${APP_ROOT}/current}"
SHARED_ROOT="${SHARED_ROOT:-${APP_ROOT}/shared}"
DEPLOY_LOG="${DEPLOY_LOG:-${SHARED_ROOT}/deployments.log}"
RAILS_ENV_FILE="${RAILS_ENV_FILE:-/etc/mitsubachi/rails.env}"
EXTERNAL_HDD="${EXTERNAL_HDD:-/mnt/external-hdd}"
MITSUBACHI_HDD_ROOT="${MITSUBACHI_HDD_ROOT:-${EXTERNAL_HDD}/mitsubachi}"
FILE_STORAGE_ROOT="${FILE_STORAGE_ROOT:-${MITSUBACHI_HDD_ROOT}/files}"
DRIVE_ITEMS_ROOT="${DRIVE_ITEMS_ROOT:-${FILE_STORAGE_ROOT}/drive_items}"
BULK_DOWNLOAD_TMP="${BULK_DOWNLOAD_TMP:-${MITSUBACHI_HDD_ROOT}/tmp/bulk_downloads}"
POSTGRES_BACKUP_DIR="${POSTGRES_BACKUP_DIR:-${MITSUBACHI_HDD_ROOT}/backups/postgres}"
STORAGE_BACKUP_DIR="${STORAGE_BACKUP_DIR:-${MITSUBACHI_HDD_ROOT}/backups/storage}"
SERVICE_NAME="${SERVICE_NAME:-mitsubachi-api}"
LOCK_DIR="${LOCK_DIR:-/tmp/mitsubachi-infra-locks}"
CURRENT_STAGE="${CURRENT_STAGE:-init}"
SECRET_KEYS_REGEX='^(DATABASE_URL|RAILS_MASTER_KEY|SECRET_KEY_BASE|RESEND_API_KEY)='

log() {
  printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${0##*/}" "$*" >&2
}

die() {
  printf '[%s] [%s] エラー: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${0##*/}" "$*" >&2
  exit 1
}

on_error() {
  local line_no="$1"
  local exit_code="$2"
  printf '[%s] [%s] エラー: 処理段階=%s 行=%s 終了コード=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${0##*/}" "${CURRENT_STAGE}" "${line_no}" "${exit_code}" >&2
}
trap 'on_error "$LINENO" "$?"' ERR

set_stage() {
  CURRENT_STAGE="$1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "この処理には root 権限が必要です。sudo で再実行してください。"
}

require_not_root() {
  [[ "${EUID}" -ne 0 ]] || die "この処理は root ではなく deploy ユーザーで実行してください。"
}

require_command() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "必須コマンドが見つかりません: ${cmd}"
  done
}

backup_if_exists() {
  local path="$1"
  if [[ -e "${path}" || -L "${path}" ]]; then
    local backup="${path}.bak.$(date -u '+%Y%m%dT%H%M%SZ')"
    cp -a -- "${path}" "${backup}"
    log "既存設定を退避しました: ${path} -> ${backup}"
  fi
}

ensure_dir() {
  local owner="$1"
  local mode="$2"
  local path
  shift 2
  for path in "$@"; do
    install -d -o "${owner%%:*}" -g "${owner##*:}" -m "${mode}" -- "${path}"
  done
}

require_mountpoint() {
  local path="${1:-${EXTERNAL_HDD}}"
  mountpoint -q -- "${path}" || die "${path} は mount point ではありません。外付け HDD 未 mount のまま処理するとルートファイルシステムへ誤保存するため停止します。"
}

require_writable_dir() {
  local path="$1"
  [[ -d "${path}" ]] || die "ディレクトリが存在しません: ${path}"
  [[ -w "${path}" ]] || die "ディレクトリへ書き込めません: ${path}"
}

require_readable_dir() {
  local path="$1"
  [[ -d "${path}" ]] || die "ディレクトリが存在しません: ${path}"
  [[ -r "${path}" ]] || die "ディレクトリを読み取れません: ${path}"
}

require_filesystem_rw() {
  local dir="$1"
  local tmp
  [[ -d "${dir}" ]] || die "ディレクトリが存在しません: ${dir}"
  tmp="$(mktemp "${dir}/.rw-check.XXXXXX")"
  rm -f -- "${tmp}"
}

require_disk_free_kb() {
  local path="$1"
  local required_kb="$2"
  local available_kb
  available_kb="$(df -Pk -- "${path}" | awk 'NR==2 {print $4}')"
  [[ "${available_kb}" =~ ^[0-9]+$ ]] || die "failed to read free space for ${path}"
  (( available_kb >= required_kb )) || die "空き容量が不足しています: ${path} 必要=${required_kb}KiB 利用可能=${available_kb}KiB"
}

validate_safe_basename() {
  local value="$1"
  [[ -n "${value}" ]] || die "空の名前は許可しません。"
  [[ "${value}" != *".."* ]] || die "危険な名前です。'..' を含めることはできません: ${value}"
  [[ "${value}" != *"/"* && "${value}" != *"\\"* ]] || die "危険な名前です。path separator を含めることはできません: ${value}"
  [[ "${value}" != *[[:space:]]* ]] || die "危険な名前です。空白を含めることはできません: ${value}"
  # Bash の通常の文字列引数は NUL byte を保持できない。NUL の混入は
  # 呼び出し境界で切り詰められるため、ここでは path traversal と shell で
  # 意味を持ちやすい文字の拒否を明示的に行う。
  [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] || die "危険な名前です。許可外の文字を含んでいます: ${value}"
}

load_systemd_env_file() {
  local file="$1"
  [[ -f "${file}" ]] || die "環境変数ファイルが存在しません: ${file}"
  # systemd EnvironmentFile は shell の source とは別物として扱う。
  # ここで `source /etc/mitsubachi/rails.env` を使うと、誤って混入した
  # `$(...)` やバッククォートが deploy / backup 実行時に評価される危険がある。
  # そのため KEY=VALUE の形だけを自前で読み、VALUE は絶対にコマンドとして
  # 評価しない。秘密情報は読み込むが、標準出力やログへは出さない。
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" == *"="* ]] || die "環境変数ファイルの行形式が不正です: ${file}"
    local key="${line%%=*}"
    local value="${line#*=}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "環境変数名が不正です: ${file}: ${key}"
    value="${value%$'\r'}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    fi
    export "${key}=${value}"
  done < "${file}"
}

redact_env_line() {
  local line="$1"
  if [[ "${line}" =~ ${SECRET_KEYS_REGEX} ]]; then
    printf '%s=<redacted>\n' "${line%%=*}"
  else
    printf '%s\n' "${line}"
  fi
}

health_check_retry() {
  local url="$1"
  local attempts="${2:-30}"
  local delay="${3:-2}"
  local i code
  require_command curl
  for ((i = 1; i <= attempts; i++)); do
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "${url}" || true)"
    if [[ "${code}" == "200" ]]; then
      log "health check 成功: ${url}"
      return 0
    fi
    log "health check 待機中 (${i}/${attempts}): ${url} の応答=${code:-curl-error}"
    sleep "${delay}"
  done
  die "health check に失敗しました: ${url}"
}

atomic_symlink_switch() {
  local target="$1"
  local link="$2"
  local parent tmp_link
  [[ -d "${target}" ]] || die "切り替え先ディレクトリが存在しません: ${target}"
  parent="$(dirname -- "${link}")"
  tmp_link="${parent}/.${link##*/}.tmp.$$"
  ln -sfn -- "${target}" "${tmp_link}"
  mv -Tf -- "${tmp_link}" "${link}"
}

with_lock() {
  local name="$1"
  mkdir -p -- "${LOCK_DIR}"
  exec 9>"${LOCK_DIR}/${name}.lock"
  flock -n 9 || die "別の ${name} 処理が実行中です。同時実行は release symlink や backup 世代を壊す可能性があるため停止します。"
}

private_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local a b c d
  IFS=. read -r a b c d <<< "${ip}"
  for octet in "${a}" "${b}" "${c}" "${d}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] && (( octet >= 0 && octet <= 255 )) || return 1
  done
  (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 ))
}

ipv4_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "${ip}"
  printf '%u\n' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

cidr_contains_ipv4() {
  local cidr="$1"
  local ip="$2"
  [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1
  [[ "${cidr}" != "0.0.0.0/0" ]] || return 1
  local network="${cidr%/*}"
  local prefix="${cidr#*/}"
  private_ipv4 "${network}" || return 1
  private_ipv4 "${ip}" || return 1
  local network_int ip_int mask
  network_int="$(ipv4_to_int "${network}")"
  ip_int="$(ipv4_to_int "${ip}")"
  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  (( (network_int & mask) == (ip_int & mask) ))
}

repo_root() {
  printf '%s\n' "${REPO_ROOT}"
}
