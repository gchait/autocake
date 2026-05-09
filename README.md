# autocake

Fully automated SQM ([cake](https://www.bufferbloat.net/projects/codel/wiki/Cake/)) bandwidth tuner for Linux.

Measures your link, picks the bandwidth caps that keep latency under load within an adaptive margin of idle, applies cake, and verifies the result. Zero flags, zero env vars, zero per-rig tuning constants — every decision comes from observed link characteristics.

## Why

[Bufferbloat](https://www.bufferbloat.net/) is the latency spike that happens when an oversized buffer somewhere along your path queues up packets under load. Web pages stall, gaming gets choppy, video calls go sideways — even when your raw bandwidth is fine. The fix is to install a smart queue (`cake`) at the bottleneck and shape traffic just below the link's true capacity.

The hard part isn't the qdisc. It's picking the cap. Too high and the bottleneck stays upstream of cake, so cake doesn't help. Too low and you give up bandwidth for nothing. The optimal cap depends on the link, the time of day, and how the path is congested — so a one-shot manual setting drifts.

`autocake` measures the link end-to-end (HTTP latency to a connectivity-check endpoint, throughput across a parallel mirror pool), walks a percentage ladder until it finds a cap that keeps loaded latency within an adaptive threshold, refines it with binary search, and re-verifies stability before committing.

## Usage

```bash
git clone https://github.com/<your-username>/autocake.git
cd autocake
sudo ./autocake.sh
```

Run on demand. `cake` state persists until reboot or `tc qdisc del`, so there's no daemon and nothing to schedule — re-run when your link, ISP plan, or topology changes. If you want it on `PATH`, alias it (`alias autocake='sudo ~/Projects/autocake/autocake.sh'`) or symlink it into `/usr/local/bin` yourself.

To remove shaping:

```bash
sudo tc qdisc del dev <iface> root
sudo tc qdisc del dev <iface> ingress
sudo ip link del ifb0
```

## Requirements

| Component    | Version   | Reason                                       |
| ------------ | --------- | -------------------------------------------- |
| Linux kernel | ≥ 4.19    | `sch_cake` mainlined Oct 2018                |
| iproute2     | ≥ 4.19    | `tc` cake support, same release              |
| curl         | ≥ 7.36    | `--next` (HTTP connection reuse for latency) |
| bash         | ≥ 3.1     | array-append `+=`                            |
| Other tools  | `tc`, `ip`, `awk`, `head`, `flock`, `modprobe` | preflighted at startup       |

`autocake` validates kernel + iproute2 cake support at startup by attaching a no-op cake qdisc to `lo`, and checks curl `--next` via `--help all`. If either fails it exits with a clear error before doing any measurement work.

## How it works

1. **Detect interface** — first device on the default route (`ip route show default`).
2. **Pick a latency probe backend** — tries Google `generate_204`, Firefox `detectportal`, Apple captive check, then Cloudflare. Connectivity-check endpoints come first because they're built for high-frequency polling and don't trip Cloudflare's small-endpoint rate limits during heavy automated use.
3. **Idle baseline** — three bursts of HTTP latency samples, picks the median burst's P75 and jitter (P95 − P25). Median, not min, so neither one-off clean reads nor one-off noisy reads anchor the threshold.
4. **Adaptive thresholds** — loaded latency must stay within `idle_P75 + clamp(2 × jitter, 8, 25) ms`. Loaded jitter must stay within Cloudflare AIM's "Great" ceiling (30 ms) — unless the link's idle jitter already exceeds that, in which case the gate is dropped (no cap can quiet a noisy radio).
5. **Throughput** — three parallel HTTP streams in each direction, distributed round-robin across a probe-validated pool of mirrors (Cloudflare + OVH + Hetzner + Tele2). Pool size matters: a single mirror that 429s under real load can't zero out the measurement, and a slow single path can't anchor it below the link's true capacity.
6. **Shape-or-skip** — runs the loaded probe with no shaping at all. If the unshaped link already passes both gates, exits without installing any cap. Catches well-behaved fiber where any cap below 100% is pure loss.
7. **Coarse pass** — walks 92% → 80% → 65% → 50% → 35% of measured bandwidth, applying cake at each step under bidirectional load. First cap that meets both gates wins. Parallel streams ensure the queue actually fills (a single stream often falls short of cap on fast links and produces false passes).
8. **Binary refine** — narrows toward the ceiling between the passing cap and the next-up failure (or 95% if nothing failed). Up to four iterations.
9. **Stability re-verification** — re-tests the chosen cap. If the win doesn't reproduce, steps down one rung and re-checks rather than installing a transient pass.
10. **Best-effort fallback** — if no cap meets the strict gates but the lowest-latency cap tested still cuts loaded P75 by more than a third vs unshaped, applies it anyway with a warning. RF-limited / extender links can't reach Cloudflare "Great" no matter what cap is installed, but leaving them wholly unshaped is strictly worse than capped-but-imperfect.
11. **Confidence label** — synthesizes already-collected signals (idle jitter, pool size, recheck delta vs search probe, whether step-down or best-effort was used) into a `high`/`medium`/`low` label. Pure post-processing — no extra probing.

## Limitations

These are inherent to the approach, not knobs:

- **Single-host Linux client.** Tuned for the case where your machine is the bandwidth bottleneck (typical for WiFi clients). For a router shaping a household uplink, edit `CAKE_OPTS` / `CAKE_INGRESS_OPTS` in the constants block to add `diffserv4 dual-srchost` (or `dual-dsthost` on ingress).
- **Cloudflare-dependent.** The latency fallback and one of the throughput backends is Cloudflare. Cloudflare is regionally blocked in some places (notably mainland China). `autocake` falls back to other endpoints automatically, but if all of them are blocked the script can't run.
- **HTTP probe variance is higher than ICMP.** Adaptive sampling and the median-of-bursts baseline mitigate it, but very noisy links may still pick a suboptimal cap; re-run to re-measure.
- **No link-overhead compensation.** PPPoE / DOCSIS / VDSL framing adds ~3–4% per-packet overhead that `autocake` doesn't model. Result lands within a few percent of optimal, not exact.
- **VPN as default route.** If your default route is a VPN tunnel (`tun0`, `wg0`), the tunnel gets shaped instead of the physical uplink. Check the `Interface:` line in the output before trusting the result.
- **Very fast links (≳ 1 Gbit).** Per-stream bytes can finish before the latency probe completes; the liveness check rejects samples taken after the load ended, but the script falls back to lower caps in this range rather than reporting false passes.
- **Wireless link variance dominates the cap.** On WiFi, especially through extenders, the measured "best cap" can swing 2× between runs because the radio environment isn't stationary. `autocake` chooses the right cap *for the link as it was during measurement*, not a permanent fixed point. Re-run when conditions change.

## License

MIT — see [LICENSE](LICENSE).
