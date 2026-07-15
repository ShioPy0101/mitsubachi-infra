#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/../bin/mitsubachi-infra"

if [[ "${EUID}" -ne 0 ]]; then
  echo "エラー: install_local.sh は Ruby CLI を起動するための最小 bootstrap です。root 権限で実行してください。" >&2
  echo "例: sudo ./scripts/install_local.sh --interactive" >&2
  exit 1
fi

if ! command -v ruby >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ruby-full git sudo
fi

exec ruby "${CLI}" install "$@"
