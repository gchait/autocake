# autocake — install logic.
#
# Single source of truth for both `install.sh` (curl | bash, defaults to
# /usr/local + /etc/systemd/system) and the AUR PKGBUILD (overrides to
# /usr + /usr/lib/systemd/system per Arch packaging convention).
#
# Variables follow GNU Coding Standards where they apply. SYSTEMDDIR is
# not a GNU variable: systemd's own convention is /usr/lib/systemd/system
# for distro-shipped units and /etc/systemd/system for admin-installed
# ones, so we expose it independently of PREFIX rather than deriving it.

PREFIX     ?= /usr/local
BINDIR     ?= $(PREFIX)/bin
SYSTEMDDIR ?= /etc/systemd/system
DESTDIR    ?=

INSTALL    ?= install

.PHONY: all install uninstall clean

all: autocake.service

# Generate the unit from the template so ExecStart/ExecStop point at the
# right BINDIR for whichever install path is invoking us. Relative-target
# symlink (`ln -sf autocake ...`, not an absolute path) so the link
# survives DESTDIR staging and resolves correctly once installed.
autocake.service: autocake.service.in
	sed 's|@BINDIR@|$(BINDIR)|g' $< > $@

install: autocake.service
	$(INSTALL) -Dm755 autocake.sh $(DESTDIR)$(BINDIR)/autocake
	ln -sf autocake $(DESTDIR)$(BINDIR)/autocake-off
	$(INSTALL) -Dm644 autocake.service $(DESTDIR)$(SYSTEMDDIR)/autocake.service

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/autocake
	rm -f $(DESTDIR)$(BINDIR)/autocake-off
	rm -f $(DESTDIR)$(SYSTEMDDIR)/autocake.service

clean:
	rm -f autocake.service
