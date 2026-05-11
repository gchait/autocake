# Maintainer: Guy Chait <53366531+gchait@users.noreply.github.com>
pkgname=autocake
pkgver=0.1.0
pkgrel=1
pkgdesc="Fully automated SQM (cake) bandwidth tuner for Linux Wi-Fi workstations"
arch=('any')
url="https://github.com/gchait/autocake"
license=('MIT')
depends=('bash' 'iproute2' 'curl')
# `make` is the only build-time tool we need that isn't in `base`. coreutils
# (install, ln, sed) and bash are already pulled in by base/base-devel.
makedepends=('make')
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')
install=$pkgname.install

package() {
  cd "$pkgname-$pkgver"

  # PREFIX=/usr per FHS for distro packages (/usr/local is admin-owned).
  # SYSTEMDDIR=/usr/lib/systemd/system per systemd's Unit Load Path: that
  # path is for distro-shipped units, /etc/systemd/system is reserved for
  # local admin overrides and `systemctl enable` symlinks.
  make install \
    DESTDIR="$pkgdir" \
    PREFIX=/usr \
    SYSTEMDDIR=/usr/lib/systemd/system

  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
}
