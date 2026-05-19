# autocake

Fully automated SQM ([cake](https://www.bufferbloat.net/projects/codel/wiki/Cake/)) bandwidth tuner for a Linux Wi-Fi
workstation.

Measures your link, picks the bandwidth caps that keep latency under load within an adaptive margin of idle, applies
`cake`, and verifies the result. Zero flags, zero env vars, zero per-rig tuning constants — every decision comes from
observed link characteristics.

## Why

[Bufferbloat](https://www.bufferbloat.net/) is the latency spike that happens when an oversized buffer somewhere along
your path queues up
packets under load. Web pages stall, gaming gets choppy, video calls go sideways — even when your raw bandwidth is fine.
The fix is to install a smart queue (`cake`) at the bottleneck and shape traffic just below the link's true capacity.

The hard part isn't the qdisc. It's picking the cap. Too high and the bottleneck stays upstream of `cake`, so `cake`
doesn't help. Too low and you give up bandwidth for nothing. The optimal cap depends on the link, the time of day,
and how the path is congested — so a one-shot manual setting drifts. This drift is most acute on Wi-Fi (signal strength,
channel contention, and AP load shift across the day), which is what `autocake` is built for.

`autocake` measures the link end-to-end (HTTP latency to a connectivity-check endpoint, throughput across a parallel
mirror pool), walks a percentage ladder until it finds a cap that keeps loaded latency within an adaptive threshold,
refines it with binary search, and re-verifies stability before committing.

## Install

**Arch-based** ([AUR](https://aur.archlinux.org/packages/autocake)):

```bash
yay -S autocake
```

**Any Linux** (installs to `/usr/local`):

```bash
curl -fsSL https://raw.githubusercontent.com/gchait/autocake/main/install.sh | sudo bash
```

**From source**:

```bash
git clone https://github.com/gchait/autocake.git
cd autocake
sudo make install
```

All three install the same three things: `autocake` on `PATH`, the `autocake-off` teardown symlink next to it, and an
`autocake.service` systemd unit — **shipped but not enabled**. Path differences follow filesystem conventions: AUR
lands the script in `/usr/bin/` and the unit in `/usr/lib/systemd/system/` (per Arch packaging policy and systemd's
[Unit Load Path](https://www.freedesktop.org/software/systemd/man/systemd.unit.html#Unit%20File%20Load%20Path) — that
hierarchy is for distro-shipped units, while `/etc/systemd/system/` is reserved for local admin overrides). The
universal installer goes the other way (`/usr/local/bin/` + `/etc/systemd/system/`) since it isn't tracked by a
package manager.

## Usage

Run on demand (auto-elevates with `sudo` if you aren't already root):

```bash
sudo autocake
```

Tear down shaping:

```bash
sudo autocake-off
```

`cake` state lives in the kernel only and is wiped at every reboot, so by default you re-run `autocake` after each
boot. There's no daemon and nothing to schedule — re-run when your link, ISP plan, or topology changes.

## Optional: run on every boot (systemd)

The unit ships with the install but is left disabled per Arch packaging policy (and same default in the universal
installer for symmetry). If you'd rather have it measure-and-apply automatically at startup, enable it:

```bash
sudo systemctl enable --now autocake.service
```

`--now` runs it immediately so you can see the result without rebooting. To watch the run live, follow the journal:

```bash
journalctl -u autocake.service -f
```

To turn it off:

```bash
sudo systemctl disable --now autocake.service
```

Re-measuring every boot (rather than persisting the last cap to disk) is deliberate: on a Wi-Fi link (especially
through an extender) the right cap depends on *current* RF conditions, not yesterday's, and a fresh ~30 s probe at
boot is far cheaper than installing a stale cap.

The unit fires once per boot and exits. There's intentionally no timer here: re-running `autocake` mid-session would
contend with the very traffic it's trying to shape, and a periodic cap chosen at 04:00 doesn't transfer to the link's
prime-time RF environment anyway. If you find the boot-time measurement isn't holding through long sessions on a
Wi-Fi-extender link, manually re-running is still the right answer — the script is built for that.

### Why the unit looks the way it does

Four points on the unit's syntax, since they're easy to get wrong if you're writing your own from scratch:

- `Wants=network-online.target` + `After=network-online.target` together are the documented way to wait for *real*
  connectivity. `network.target` only signals that the network *stack* is up, which is too early — the throughput probe
  needs an actually-routable internet path. ([systemd.io: Running Services After the Network Is Up](
  https://systemd.io/NETWORK_ONLINE/))
- `Type=oneshot` + `RemainAfterExit=yes` is the right pair for a measurement script: systemd waits for `autocake` to
  finish (so dependent units don't race against an unshaped link), and then keeps the unit `active` afterward instead of
  flipping to `inactive (dead)` and looking like a failure in `systemctl status`. ([Red Hat: oneshot service type](
  https://www.redhat.com/en/blog/systemd-oneshot-service))
- `ExecStop=…/autocake-off` makes `systemctl stop` (and `disable --now`) actually revert the kernel state instead of
  just flipping the unit to inactive while leaving `cake` applied — without it, "stopping" the service is a silent
  no-op until reboot, which is a footgun.
- `WantedBy=multi-user.target` makes `systemctl enable` create the symlink that actually runs the unit at boot.

## Uninstall

```bash
# AUR
sudo pacman -R autocake

# curl | bash install
curl -fsSL https://raw.githubusercontent.com/gchait/autocake/main/install.sh | sudo bash -s -- uninstall

# from source
sudo make uninstall
```

## Requirements

| Component    | Version                                        | Reason                                       |
|--------------|------------------------------------------------|----------------------------------------------|
| Linux kernel | ≥ 4.19                                         | `sch_cake` mainlined Oct 2018                |
| iproute2     | ≥ 4.19                                         | `tc` `cake` support, same release            |
| curl         | ≥ 7.36                                         | `--next` (HTTP connection reuse for latency) |
| bash         | ≥ 3.1                                          | array-append `+=`                            |
| Other tools  | `tc`, `ip`, `awk`, `head`, `flock`, `modprobe` | preflighted at startup                       |

`autocake` validates kernel + iproute2 `cake` support at startup by attaching a no-op `cake` qdisc to `lo`, and checks
`curl --version` ≥ 7.36 (the release that introduced `--next`). If either fails it exits with a clear error before doing
any measurement work.

## How it works

1. **Detect interface** — first device on the default route (`ip route show default`).
2. **Pick a latency probe backend** — tries Google `generate_204`, Firefox `detectportal`, Apple captive check, then
   Cloudflare. Connectivity-check endpoints come first because they're built for high-frequency polling and don't trip
   Cloudflare's small-endpoint rate limits during heavy automated use.
3. **Idle baseline** — three bursts of HTTP latency samples, picks the median burst's P75 and jitter (P95 − P25).
   Median, not min, so neither one-off clean reads nor one-off noisy reads anchor the threshold.
4. **Adaptive thresholds** — loaded latency must stay within `idle_P75 + clamp(2 × jitter, 8, 25) ms`. Loaded jitter
   must stay within Cloudflare AIM's "Great" ceiling (30 ms) — unless the link's idle jitter already exceeds that, in
   which case the gate is dropped (no cap can quiet a noisy radio).
5. **Throughput** — up to three parallel HTTP streams in each direction, distributed round-robin across a
   probe-validated pool of mirrors (Cloudflare + OVH + Hetzner + Linode + Vultr + Scaleway — six independent
   operators, so no single vendor decision can take more than one out at once). Probes run in parallel, so total
   startup cost is bounded by one timeout regardless of pool size. Stream count is capped at the live pool size so
   no single mirror gets two streams (Cloudflare 429s under sustained 2-stream load, which would cascade into stalled
   probes). Pool size matters: a single mirror that 429s under real load can't zero out the measurement, and a slow
   single path can't anchor it below the link's true capacity.
6. **Shape-or-skip** — runs the loaded probe with no shaping at all. If the unshaped link already passes both gates,
   exits without installing any cap. Catches well-behaved links where any cap below 100% is pure loss.
7. **Coarse pass** — walks 92% → 80% → 65% → 50% → 35% of measured bandwidth, applying `cake` at each step under
   bidirectional load. First cap that meets both gates wins. Parallel streams ensure the queue actually fills (a single
   stream often falls short of cap on fast links and produces false passes).
8. **Binary refine** — narrows toward the ceiling between the passing cap and the next-up failure (or 95% if nothing
   failed). Up to four iterations.
9. **Stability re-verification** — re-tests the chosen cap. If the win doesn't reproduce, steps down one rung and
   re-checks rather than installing a transient pass.
10. **Best-effort fallback** — if no cap meets the strict gates but the lowest-latency cap tested still cuts loaded P75
    by more than a third vs unshaped, applies it anyway with a warning. RF-limited / extender links can't reach
    Cloudflare "Great" no matter what cap is installed, but leaving them wholly unshaped is strictly worse than
    capped-but-imperfect.
11. **Confidence label** — synthesizes already-collected signals (idle jitter, pool size, recheck delta vs search probe,
    whether step-down or best-effort was used) into a `high`/`medium`/`low` label. Pure post-processing — no extra
    probing.

## Limitations

These are inherent to the approach, not knobs:

- **Wi-Fi single-host only.** Designed for a Linux laptop or desktop on Wi-Fi (often through an extender) shaping its
  own uplink. Routers, household-wide shaping, wired-only setups, and DSL/cable links that need link-layer overhead
  modeling are out of scope by design — [sqm-scripts](https://github.com/tohojo/sqm-scripts) is a better fit for those.
- **External HTTP backends.** Auto-measurement requires reaching public probe endpoints (Google `generate_204`,
  Firefox `detectportal`, Apple captive check, Cloudflare, plus mirrors at OVH / Hetzner / Linode / Vultr /
  Scaleway). The pool, round-robin, and liveness checks tolerate individual outages and rate limits, but the
  approach is structurally dependent on these services staying reachable and behaving consistently — that's the
  cost of measurement-based tuning that static shapers don't pay. Cloudflare in particular is regionally blocked in
  some places (notably mainland China); if all backends are blocked, the script can't run.
- **HTTP probe variance is higher than ICMP.** Adaptive sampling and the median-of-bursts baseline mitigate it, but very
  noisy links may still pick a suboptimal cap; re-run to re-measure.
- **VPN as default route.** If your default route is a VPN tunnel (`tun0`, `wg0`), the tunnel gets shaped instead of the
  physical uplink. Check the `Interface:` line in the output before trusting the result.
- **Very fast links (≳ 1 Gbit).** Reachable on Wi-Fi 6/6E/7 with wide channels and a clean radio environment.
  Per-stream bytes can finish before the latency probe completes; the liveness check rejects samples taken after the
  load ended, but the script falls back to lower caps in this range rather than reporting false passes.
- **Wireless link variance dominates the cap.** On Wi-Fi, especially through extenders, the measured "best cap" can
  swing 2× between runs because the radio environment isn't stationary. `autocake` chooses the right cap *for the link
  as it was during measurement*, not a permanent fixed point. Re-run when conditions change.
