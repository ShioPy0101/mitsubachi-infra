#!/usr/bin/env bash

# 呼び出し元は release を checkout した後に実行する。global Ruby と Puma は変更しない。
prepare_release_ruby() {
  local release="$1" ruby_version ruby_build
  [[ -f "${release}/.ruby-version" ]] || { printf 'missing release .ruby-version\n' >&2; return 1; }
  ruby_version="$(cat "${release}/.ruby-version")"
  [[ "${ruby_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'invalid release .ruby-version\n' >&2; return 1; }
  command -v rbenv >/dev/null || { printf 'rbenv is required; run infra install first\n' >&2; return 1; }
  if ! rbenv versions --bare | grep -Fx -- "${ruby_version}" >/dev/null; then
    ruby_build="$(rbenv root)/plugins/ruby-build"
    if [[ -d "${ruby_build}/.git" ]]; then
      git -C "${ruby_build}" diff --exit-code HEAD || return 1
      git -C "${ruby_build}" fetch origin HEAD || return 1
      git -C "${ruby_build}" merge --ff-only FETCH_HEAD || return 1
    else
      mkdir -p -- "$(dirname -- "${ruby_build}")" || return 1
      git clone -- https://github.com/rbenv/ruby-build.git "${ruby_build}" || return 1
    fi
    RUBY_CONFIGURE_OPTS=--disable-install-doc rbenv install "${ruby_version}" || return 1
  fi
  # 環境ファイルや呼び出し元の指定より release の宣言を優先する。
  unset RBENV_DIR
  export RBENV_VERSION="${ruby_version}"
  rbenv exec ruby -e 'abort RUBY_VERSION unless RUBY_VERSION == ARGV.fetch(0)' "${ruby_version}"
}
