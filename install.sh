#!/usr/bin/env bash
# Universal installer for autocake.
#
# Downloads the latest release tarball and runs `make install` from it,
# so the install logic stays in the Makefile (one source of truth shared
# with the AUR PKGBUILD). Installs to /usr/local by default; the systemd
# unit lands in /etc/systemd/system, the right path for admin-installed
# units (distro packages use /usr/lib/systemd/system instead).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/gchait/autocake/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/gchait/autocake/main/install.sh | sudo bash -s -- uninstall
#
# Honors:
#   PREFIX            install root (default: /usr/local)
#   SYSTEMDDIR        unit directory (default: /etc/systemd/system)
#   AUTOCAKE_VERSION  tag to install (default: latest GitHub release)

set -euo pipefail

REPO="gchait/autocake"
PREFIX="${PREFIX:-/usr/local}"
SYSTEMDDIR="${SYSTEMDDIR:-/etc/systemd/system}"
BINDIR="${PREFIX}/bin"
ACTION="${1:-install}"

if [ "$(id -u)" -ne 0 ]; then
  command -v sudo > /dev/null 2>&1 || {
    echo "ERROR: must run as root, and sudo is not available" >&2
    exit 1
  }
  SUDO=sudo
else
  SUDO=
fi

case "${ACTION}" in
install)
  for cmd in curl tar make install sed; do
    command -v "${cmd}" > /dev/null 2>&1 || {
      echo "ERROR: missing dependency: ${cmd}" >&2
      exit 1
    }
  done

  VERSION="${AUTOCAKE_VERSION:-latest}"
  if [ "${VERSION}" = latest ]; then
    # Resolve latest from tags.atom — first /releases/tag/v<digit>… link
    # is the most recent versioned tag. The v-prefix + leading digit
    # filter skips floating tags like `nightly`/`stable` that some repos
    # ship and that GitHub orders by tag-update time, not by semver. No
    # GitHub Release object required (a bare git tag suffices), no
    # rate-limited GitHub API, no JSON parsing.
    VERSION=$(curl -fsSL "https://github.com/${REPO}/tags.atom" |
      grep -m1 -oE '/releases/tag/v[0-9][^"]*' |
      sed 's|/releases/tag/||')
    if [ -z "${VERSION}" ]; then
      echo "ERROR: cannot resolve latest tag — set AUTOCAKE_VERSION explicitly" >&2
      exit 1
    fi
  fi
  PKGVER="${VERSION#v}"

  TMP=$(mktemp -d)
  trap 'rm -rf "${TMP}"' EXIT

  echo "Downloading autocake ${VERSION}..."
  curl -fsSL "https://github.com/${REPO}/archive/refs/tags/${VERSION}.tar.gz" |
    tar -xz -C "${TMP}"
  cd "${TMP}/autocake-${PKGVER}"

  echo "Installing to ${BINDIR} (unit at ${SYSTEMDDIR})..."
  ${SUDO} make install PREFIX="${PREFIX}" SYSTEMDDIR="${SYSTEMDDIR}"

  # Notify systemd that the unit changed. Strictly only required on the
  # upgrade path (re-installing over an already-loaded unit) — for a
  # fresh install, systemd loads the unit lazily on first reference. But
  # standard installer hygiene (matches tailscale/ollama/docker) and
  # symmetric with the uninstall path below.
  ${SUDO} systemctl daemon-reload 2> /dev/null || true

  cat << EOF

autocake ${VERSION} installed.
  Run on demand:        sudo autocake
  Tear down shaping:    sudo autocake-off
  Apply at every boot:  sudo systemctl enable --now autocake.service

EOF
  ;;
uninstall)
  echo "Removing autocake from ${BINDIR}..."
  ${SUDO} systemctl disable --now autocake.service 2> /dev/null || true
  ${SUDO} rm -f "${BINDIR}/autocake" "${BINDIR}/autocake-off"
  ${SUDO} rm -f "${SYSTEMDDIR}/autocake.service"
  ${SUDO} systemctl daemon-reload 2> /dev/null || true
  echo "Removed."
  ;;
*)
  echo "Usage: install.sh [install|uninstall]" >&2
  exit 1
  ;;
esac
