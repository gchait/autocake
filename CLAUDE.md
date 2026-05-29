## Architecture you won't get from grep

- **Mode dispatch is by `argv[0]`**, not flags: `autocake` applies, `autocake-off` tears down. The `Makefile` installs
  `autocake-off` as a symlink to `autocake`. `INVOKED_AS` captures the literal path before sudo re-exec so the symlink
  basename survives elevation.
- **Single-instance lock + state in `/run/autocake/`** (root-owned 0700). Lock on FD 9 via `flock`; `state` file
  persists the iface that was actually shaped so off-mode cleans the right device even if the default route shifted
  between apply and teardown. Both vanish at reboot, matching cake's kernel-only lifetime.
- **`SQM_COMMITTED` flag** flips to 1 only after the final successful `sqm_apply`. The EXIT trap calls `sqm_off` unless
  committed — any early exit (preflight fail, SIGTERM mid-search, `set -u` violation) leaves the link unshaped rather
  than half-shaped.
- **`sqm_apply` / `sqm_off` are symmetric.** `sqm_off` accepts an iface arg so it can clean a previously-shaped iface
  that differs from today's default route.
- **`WORKDIR=$(mktemp -d)`** holds per-stream curl output and the parallel probe scratch; `exit_cleanup` `rm -rf`s it.
- **Project-namespaced ifb device `ifb-autocake`** (12 chars, under IFNAMSIZ=15) — never collide with a foreign `ifb0`.
- **`CAKE_OPTS="besteffort"` is intentional** on single-host Wi-Fi. Don't switch to `diffserv3`: most egress is CS0,
  intra-host fairness comes from cake's flow isolation, and Wi-Fi radio variance dwarfs any tier gap.

## Don't break

- The zero-flags / zero-env-vars promise — anything user-facing goes through `argv[0]` dispatch or autodetection.
- `set -uo pipefail` without `-e` is deliberate: critical `tc` / `ip` calls are checked explicitly so we can run an
  EXIT-trap rollback; blanket `-e` would skip the rollback.
- The EXIT trap + `SQM_COMMITTED` invariant. Don't add early `exit 0` paths after partial apply.
- Backend pools (`DOWNLOAD_BACKENDS`, `LATENCY_BACKENDS`) are ASN-diverse on purpose. When editing, keep at least 3
  independent operators so a single vendor decision can't zero out measurement.

## Verify changes

```
bash -n autocake.sh && shellcheck autocake.sh
```

(No CI / no enforced level — the script keeps a few inline `# shellcheck disable=SC2086` directives at intentional
word-split sites.)

## Install / test flow

```
make install                  # PREFIX=/usr/local SYSTEMDDIR=/etc/systemd/system by default
sudo autocake                 # measure + apply
sudo autocake-off             # revert
```
