#!/bin/sh

set -eu

REPO="zerotier/ZeroTierOne"
STATE_FILE="/var/lib/zerotier-one/.zerotierone-installed-version"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
WORK_BASE="/tmp/zerotierone-build"
TMP_DIR=""
FORCE=0
MANAGE_SERVICE=1
WITH_RUST=0

log() {
  printf '%s\n' "$*"
}

usage() {
  cat <<EOF
Usage: $0 [--force] [--no-service] [--with-rust]

  --force      Rebuild/reinstall even if installed version is already latest.
  --no-service Skip stop/register/start of zerotier-one service.
  --with-rust  Install rust toolchain and build with SSO enabled (default: off).
EOF
}

while [ "${1:-}" != "" ]; do
  case "$1" in
    --force)
      FORCE=1
      ;;
    --no-service)
      MANAGE_SERVICE=0
      ;;
    --with-rust)
      WITH_RUST=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Need to run as root."
    exit 1
  fi
}

clean_version() {
  echo "$1" | sed 's/^v//; s/[^0-9.].*$//; s/[[:space:]]//g'
}

version_is_greater() {
  local a b winner
  a="$(clean_version "$1")"
  b="$(clean_version "$2")"
  if [ "$a" = "$b" ]; then
    return 1
  fi
  winner="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)"
  [ "$winner" = "$a" ]
}

get_state_version() {
  if [ -r "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  fi
}

set_state_version() {
  install -d -m 0755 -o root -g root /var/lib/zerotier-one
  echo "$1" >"$STATE_FILE"
  chmod 0644 "$STATE_FILE"
}

ensure_deps() {
  if ! command -v apk >/dev/null 2>&1; then
    log "This script is prepared for Alpine Linux (apk)."
    exit 1
  fi

  APK_PACKAGES="
    ca-certificates
    wget
    tar
    gzip
    build-base
    linux-headers
    openssl
    openssl-dev
  "
  for optional in miniupnpc miniupnpc-dev; do
    if apk info -e "$optional" >/dev/null 2>&1; then
      APK_PACKAGES="$APK_PACKAGES $optional"
    fi
  done

  if [ "$WITH_RUST" -eq 1 ]; then
    APK_PACKAGES="$APK_PACKAGES
      rust
      cargo
    "
  fi

  apk add --no-cache $APK_PACKAGES
}

get_latest_release() {
  local tag
  tag="$(wget -qO- "$API_URL" | awk -F'"' '/"tag_name"/ {print $4; exit}')"
  if [ -z "$tag" ]; then
    log "Failed to parse latest release tag."
    exit 1
  fi
  clean_version "$tag"
}

build_and_install() {
  local version="$1"
  local url="https://github.com/${REPO}/archive/refs/tags/${version}.tar.gz"
  local archive="$TMP_DIR/${version}.tar.gz"
  local topdir
  local src

  mkdir -p "$TMP_DIR"
  log "Downloading source ${version}..."
  wget -qO "$archive" "$url"

  topdir="$(tar -tzf "$archive" | head -n 1 | cut -d/ -f1)"
  if [ -z "$topdir" ]; then
    log "Unable to inspect tarball."
    exit 1
  fi
  tar -xzf "$archive" -C "$TMP_DIR"
  src="$TMP_DIR/$topdir"

  log "Building ZeroTierOne ${version}..."
  cd "$src"

  if [ "$WITH_RUST" -eq 1 ]; then
    make -j"$(nproc)"
  else
    # Skip SSO-related Rust dependency for faster/cleaner Alpine builds.
    make ZT_SSO_SUPPORTED=0 -j"$(nproc)"
  fi
  make install
}

write_openrc_service() {
  local init_script="/etc/init.d/zerotier-one"

  if [ -x "$init_script" ]; then
    return
  fi

  cat >/etc/init.d/zerotier-one <<'EOF'
#!/sbin/openrc-run

name="zerotier-one"
description="ZeroTier One daemon"

command="/usr/sbin/zerotier-one"
command_args="-d"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}

start_pre() {
    rm -f "$pidfile"
}
EOF

  chmod 755 /etc/init.d/zerotier-one
}

service_restart() {
  if [ "$MANAGE_SERVICE" -eq 0 ]; then
    return
  fi

  if ! command -v rc-service >/dev/null 2>&1; then
    log "rc-service not found. OpenRC not available."
    return
  fi

  write_openrc_service
  rc-update add zerotier-one default || true

  if rc-service zerotier-one status >/dev/null 2>&1; then
    rc-service zerotier-one restart
  else
    rc-service zerotier-one start
  fi
}

cleanup() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

main() {
  require_root
  ensure_deps

  TMP_DIR="$(mktemp -d "${WORK_BASE}.XXXXXX")"

  latest="$(get_latest_release)"
  installed="$(get_state_version || true)"
  installed="$(clean_version "$installed")"

  if [ -n "${installed:-}" ]; then
    if [ "$installed" = "$latest" ] && [ "$FORCE" -eq 0 ]; then
      log "Already at latest version: $latest"
      if [ "$MANAGE_SERVICE" -eq 1 ] && command -v rc-service >/dev/null 2>&1; then
        rc-service zerotier-one status >/dev/null 2>&1 || service_restart
      fi
      log "Skip build."
      exit 0
    fi

    if ! version_is_greater "$latest" "$installed"; then
      log "Existing installed version ($installed) is newer than latest known release ($latest)."
      log "No changes made."
      exit 0
    fi
  else
    if [ "$FORCE" -eq 0 ]; then
      log "No previous script-installed version record found. Fresh install."
    else
      log "Forced install requested."
    fi
  fi

  if [ "$MANAGE_SERVICE" -eq 1 ] && command -v rc-service >/dev/null 2>&1; then
    log "Stopping existing zerotier-one service."
    rc-service zerotier-one stop || true
  fi

  if [ -n "${installed:-}" ]; then
    log "Updating zerotier-one ${installed} -> ${latest}"
  else
    log "Installing zerotier-one ${latest}"
  fi

  build_and_install "$latest"

  set_state_version "$latest"

  service_restart

  if [ -x /usr/sbin/zerotier-one ]; then
    /usr/sbin/zerotier-one -h >/tmp/zerotierone-help.txt 2>&1 || true
    rm -f /tmp/zerotierone-help.txt
  fi

  log "Done. Installed zerotier-one ${latest}."
}

main "$@"
