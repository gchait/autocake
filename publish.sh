#!/usr/bin/env bash
# publish.sh — prepare an autocake AUR submission.
#
# Walks through the pre-push steps interactively. Does NOT push to
# GitHub or AUR — both are left to the user so credentials and
# identity stay with them. The script pauses at each external action
# and resumes after Enter.
#
# Usage: ./publish.sh [VERSION]
#   VERSION defaults to the pkgver from PKGBUILD (without leading v).
#
# Requires (locally): git, curl, sha256sum, awk, makepkg. Run from Arch.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
cd "${REPO_ROOT}"

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
  VERSION=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
fi
TAG="v${VERSION}"

# Pull the upstream URL from PKGBUILD instead of hard-coding the org/repo
# slug, so a fork that updates PKGBUILD's url= field doesn't need to also
# patch this script.
REPO_URL=$(awk -F'"' '/^url=/{print $2; exit}' PKGBUILD)

step() { printf '\n=== %s ===\n' "$*"; }
prompt() {
  printf '%s ' "$*"
  read -r _
}

# --- preflight ---
step "Preflight"
[ -f PKGBUILD ] || {
  echo "ERROR: run from repo root" >&2
  exit 1
}
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "${BRANCH}" = main ] || {
  echo "ERROR: on branch ${BRANCH}, not main" >&2
  exit 1
}
[ -z "$(git status --porcelain)" ] || {
  echo "ERROR: working tree dirty — commit or stash first" >&2
  exit 1
}
PKGVER=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
[ "${PKGVER}" = "${VERSION}" ] || {
  echo "ERROR: PKGBUILD pkgver=${PKGVER} differs from requested ${VERSION}" >&2
  exit 1
}
echo "OK: clean tree, on main, PKGBUILD pkgver=${VERSION}"

# --- local tag ---
step "Local tag ${TAG}"
if git rev-parse --verify --quiet "refs/tags/${TAG}" > /dev/null; then
  echo "tag ${TAG} already exists locally — reusing"
else
  git tag -a "${TAG}" -m "autocake ${TAG}"
  echo "created annotated tag ${TAG}"
fi

# --- push tag prompt ---
step "Push tag to GitHub"
echo "Run this yourself (in any terminal):"
echo "    git push origin ${TAG}"
prompt "Press Enter once the tag is pushed (Ctrl-C to abort)."

# --- verify tarball ---
step "Verify GitHub serves the tarball"
TARBALL_URL="${REPO_URL}/archive/refs/tags/${TAG}.tar.gz"
TARBALL_PATH="/tmp/autocake-${TAG}.tar.gz"
HTTP=$(curl -fsSL -o "${TARBALL_PATH}" -w '%{http_code}' "${TARBALL_URL}" 2> /dev/null || echo "fail")
if [ "${HTTP}" != 200 ]; then
  echo "ERROR: tarball not reachable (HTTP ${HTTP}) at:" >&2
  echo "    ${TARBALL_URL}" >&2
  echo "Did you push the tag?" >&2
  exit 1
fi
SHA=$(sha256sum "${TARBALL_PATH}" | awk '{print $1}')
echo "tarball OK"
echo "sha256: ${SHA}"

# --- update PKGBUILD sha256 ---
step "Update PKGBUILD sha256sums"
awk -v sha="${SHA}" '
  /^sha256sums=/ { print "sha256sums=('"'"'" sha "'"'"')"; next }
  { print }
' PKGBUILD > PKGBUILD.tmp && mv PKGBUILD.tmp PKGBUILD
echo "PKGBUILD updated:"
grep '^sha256sums' PKGBUILD

# --- stage AUR repo ---
step "Stage AUR repo at /tmp/autocake-aur"
AURDIR="/tmp/autocake-aur"
rm -rf "${AURDIR}"
git clone "ssh://aur@aur.archlinux.org/autocake.git" "${AURDIR}" || {
  echo "ERROR: AUR clone failed. Verify your SSH key is registered at" >&2
  echo "  https://aur.archlinux.org/account/" >&2
  exit 1
}
cp PKGBUILD autocake.install "${AURDIR}/"

# --- .SRCINFO ---
step "Generate .SRCINFO"
(cd "${AURDIR}" && makepkg --printsrcinfo > .SRCINFO)

# --- final instructions ---
step "Push to AUR (run yourself)"
cat << EOF
cd ${AURDIR}
git add PKGBUILD .SRCINFO autocake.install
git commit -m "Initial release ${VERSION}"
git push
EOF
