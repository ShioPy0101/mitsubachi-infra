#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: sudo scripts/configure_local_network.sh --lan-cidr CIDR --server-ip IP [options]

Options:
  --enable-ufw             Apply UFW rules and enable UFW.
  --allow-ssh              Allow TCP 22 from --lan-cidr before enabling UFW.
  --ssh-cidr CIDR          Use a narrower SSH source CIDR. Must contain --server-ip or be private.
  --install-nginx-config   Install and enable nginx/mitsubachi-local.conf.
  --remove-default-site    Remove Nginx default site symlink. Requires --install-nginx-config.
  --dry-run                Print actions without changing UFW/Nginx.
  --help                   Show this help.
USAGE
}

LAN_CIDR=""
SERVER_IP=""
ENABLE_UFW=false
ALLOW_SSH=false
SSH_CIDR=""
INSTALL_NGINX=false
REMOVE_DEFAULT=false
DRY_RUN=false

while (($#)); do
  case "$1" in
    --lan-cidr) LAN_CIDR="${2:-}"; shift 2 ;;
    --server-ip) SERVER_IP="${2:-}"; shift 2 ;;
    --enable-ufw) ENABLE_UFW=true; shift ;;
    --allow-ssh) ALLOW_SSH=true; shift ;;
    --ssh-cidr) SSH_CIDR="${2:-}"; shift 2 ;;
    --install-nginx-config) INSTALL_NGINX=true; shift ;;
    --remove-default-site) REMOVE_DEFAULT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_root
[[ -n "${LAN_CIDR}" ]] || die "--lan-cidr is required"
[[ -n "${SERVER_IP}" ]] || die "--server-ip is required"
[[ "${LAN_CIDR}" != "0.0.0.0/0" ]] || die "0.0.0.0/0 is not allowed for LAN CIDR"
private_ipv4 "${SERVER_IP}" || die "--server-ip must be private IPv4"
cidr_contains_ipv4 "${LAN_CIDR}" "${SERVER_IP}" || die "--server-ip is not inside --lan-cidr"
if [[ -n "${SSH_CIDR}" ]]; then
  [[ "${SSH_CIDR}" != "0.0.0.0/0" ]] || die "0.0.0.0/0 is not allowed for SSH CIDR"
  cidr_contains_ipv4 "${SSH_CIDR}" "${SERVER_IP}" || die "--server-ip is not inside --ssh-cidr"
else
  SSH_CIDR="${LAN_CIDR}"
fi
if [[ "${ENABLE_UFW}" == true && "${ALLOW_SSH}" != true ]]; then
  die "--enable-ufw requires --allow-ssh so the current session is not locked out"
fi
if [[ "${REMOVE_DEFAULT}" == true && "${INSTALL_NGINX}" != true ]]; then
  die "--remove-default-site requires --install-nginx-config"
fi

run_or_echo() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

set_stage "nginx config"
# LAN HTTP の入口は Nginx :80 のみに限定する。Rails/Puma :3000 は
# localhost bind のままにして、UFW でも 3000 を開けない。ここで扱う
# Nginx 設定には HTTPS、証明書、公開 DNS 前提を一切混ぜない。
log "LAN HTTP 用 Nginx 設定を必要に応じて install します。"
if [[ "${INSTALL_NGINX}" == true ]]; then
  backup_if_exists /etc/nginx/sites-available/mitsubachi-local.conf
  run_or_echo install -o root -g root -m 0644 "${REPO_ROOT}/nginx/mitsubachi-local.conf" /etc/nginx/sites-available/mitsubachi-local.conf
  run_or_echo ln -sfn /etc/nginx/sites-available/mitsubachi-local.conf /etc/nginx/sites-enabled/mitsubachi-local.conf
  if [[ "${REMOVE_DEFAULT}" == true ]]; then
    backup_if_exists /etc/nginx/sites-enabled/default
    run_or_echo rm -f /etc/nginx/sites-enabled/default
  fi
  if [[ "${DRY_RUN}" != true ]]; then
    nginx -t
    systemctl reload nginx || systemctl restart nginx
  fi
fi

set_stage "ufw"
if [[ "${ENABLE_UFW}" == true ]]; then
  require_command ufw
  log "UFW 適用前の状態を表示します。既存ルールは削除せず、LAN からの 80/tcp と SSH だけを追加します。"
  ufw status verbose || true
  # UFW を enable する前に SSH 許可を入れる。順序を逆にすると、リモート作業中の
  # 管理者が自分自身を締め出す可能性がある。SSH は全世界ではなく LAN CIDR
  # または明示された SSH CIDR に限定する。
  run_or_echo ufw allow from "${SSH_CIDR}" to any port 22 proto tcp comment "mitsubachi ssh"
  run_or_echo ufw allow from "${LAN_CIDR}" to any port 80 proto tcp comment "mitsubachi local http"
  # 3000 と 5432 は意図的に許可しない。Rails と PostgreSQL は LAN からも
  # 直接到達できないことがこの Infra のセキュリティ境界になる。
  run_or_echo ufw --force enable
  log "UFW 適用後の状態を表示します。"
  ufw status verbose || true
else
  log "--enable-ufw が指定されていないため、UFW は変更しません。"
fi

log "LAN 設定が完了しました。"
