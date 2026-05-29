#!/bin/bash
# Two invocation modes, selected by argv[0] (symlink basename — not a flag):
#   autocake        — measure link, apply cake
#   autocake-off    — remove any cake/ifb state from a previous run
#
# Usage: ./autocake.sh                                    (apply, auto-elevates)
#        ln -s autocake.sh autocake-off; ./autocake-off   (revert)
#
# See README.md for the algorithm, requirements, and limitations.

set -uo pipefail

# Capture the literal invocation path before sudo re-exec. readlink -f
# would canonicalize symlinks away, and we need the symlink basename
# (e.g. autocake-off) to survive elevation so argv[0] dispatch works.
case "${0}" in
/*) INVOKED_AS="${0}" ;;
*) INVOKED_AS="${PWD}/${0}" ;;
esac

# Mode is decided by the symlink basename. Anything ending in -off (or
# -off.sh, for the in-repo `ln -s autocake.sh autocake-off` flow) means
# tear down; anything else means measure and apply.
case "${0##*/}" in
*-off | *-off.sh) MODE=off ;;
*) MODE=on ;;
esac

if [ "${EUID}" -ne 0 ]; then
  command -v sudo > /dev/null 2>&1 || {
    echo "ERROR: must run as root, and sudo is not available" >&2
    exit 1
  }
  exec sudo -- "${INVOKED_AS}" "${@}"
fi

for cmd in tc curl ip awk head flock modprobe sort; do
  command -v "${cmd}" > /dev/null 2>&1 || {
    echo "missing dependency: ${cmd}" >&2
    exit 1
  }
done

# Acquire a host-wide lock so two instances can't fight over the ifb
# device or tc state. The lock lives on FD 9 for the lifetime of the
# script — when this process exits (any reason) the kernel closes the FD
# and the lock releases.
#
# Putting the lock file inside a root-only 0700 directory is the only way
# to keep a local non-root user from holding an exclusive flock on it: a
# 0644 lock file is world-readable, and on Linux a read-only FD is enough
# to hold LOCK_EX. /run is the right home for runtime state on any modern
# Linux; we refuse to start without it rather than fall back to /tmp,
# which is world-writable and offers no comparable guarantee.
[ -d /run ] || {
  echo "ERROR: /run not present — autocake needs a root-owned runtime directory" >&2
  exit 1
}
LOCK_DIR="/run/autocake"
if ! mkdir -p "${LOCK_DIR}" || ! chmod 0700 "${LOCK_DIR}"; then
  echo "ERROR: cannot prepare lock directory ${LOCK_DIR}" >&2
  exit 1
fi
LOCK_FILE="${LOCK_DIR}/lock"
exec 9<> "${LOCK_FILE}" || {
  echo "ERROR: cannot open lock file ${LOCK_FILE}" >&2
  exit 1
}
if ! flock -n 9; then
  echo "ERROR: another autocake instance is running (lock: ${LOCK_FILE})" >&2
  exit 1
fi

STATE_FILE="${LOCK_DIR}/state"
SAVED_IFACE=""
if [ -r "${STATE_FILE}" ]; then
  SAVED_IFACE=$(awk -F= '/^iface=/{print $2; exit}' "${STATE_FILE}")
fi

# On-mode preflights only. Off-mode neither shapes nor probes, so cake
# kernel support and curl version are irrelevant to teardown — and a user
# reverting state on a system with stale tooling should still succeed.
if [ "${MODE}" = on ]; then
  # Preflight: cake qdisc support. Probes by attaching a no-op cake qdisc to
  # the loopback interface (and removing it immediately). Catches the kernel
  # module (sch_cake, mainlined in 4.19) and the iproute2 'cake' keyword
  # (added in 4.19) in one shot. Failing here surfaces the unsupported-kernel
  # case before any measurement work.
  modprobe sch_cake 2> /dev/null || true
  if ! tc qdisc replace dev lo root cake 2> /dev/null; then
    # Distinguish "kernel upgraded, not rebooted yet" from genuine
    # unsupported-kernel. After a package-manager kernel upgrade, the
    # running kernel's /lib/modules/$(uname -r) directory is deleted,
    # so no modules can load until reboot — including sch_cake.
    if [ ! -d "/lib/modules/$(uname -r)" ]; then
      echo "ERROR: /lib/modules/$(uname -r) is missing — running kernel's modules were removed." >&2
      echo "  This usually means the kernel package was upgraded but the system hasn't rebooted." >&2
      echo "  Reboot to load the new kernel, then re-run autocake." >&2
    else
      echo "ERROR: cake qdisc unsupported on this system." >&2
      echo "  Need: Linux >= 4.19 with CONFIG_NET_SCH_CAKE, iproute2 >= 4.19." >&2
    fi
    exit 1
  fi
  tc qdisc del dev lo root 2> /dev/null || true

  # Preflight: curl --next, used by the latency probe to reuse a single TLS
  # connection across samples. Added in curl 7.36 (March 2014). We can't use
  # `curl --help all` to detect support: --help all is itself curl 7.73+, so
  # parsing the version string is the only reliable check.
  CURL_VER="$(curl --version | awk 'NR==1{print $2}')"
  if [ "$(printf '7.36.0\n%s\n' "${CURL_VER}" | sort -V | head -n1)" != "7.36.0" ]; then
    echo "ERROR: curl ${CURL_VER} is too old; need >= 7.36 for --next." >&2
    exit 1
  fi
fi

# --- autodetected from system state ---
# In off-mode an empty IFACE is tolerable: the user may be reverting state
# on a disconnected machine, and sqm_off's ifb-device deletion still works
# without one. tc commands against an empty dev fail silently (they're all
# `2>/dev/null || true` in sqm_off), so no special-casing is needed there.
IFACE="$(ip -o route show default 2> /dev/null | awk '{print $5; exit}')"
if [ "${MODE}" = on ] && [ -z "${IFACE}" ]; then
  # At boot the Wi-Fi association races the service start. Wait up to 60s
  # (5s × 12) for a default route to appear before giving up. On an already-
  # up system the first retry finds the route immediately; on a cold boot it
  # typically resolves within 10–15s. systemd would mark the unit failed on
  # exit 1 here, so waiting avoids a spurious failure in the journal.
  _waited=0
  until
    IFACE="$(ip -o route show default 2> /dev/null | awk '{print $5; exit}')"
    [ -n "${IFACE}" ]
  do
    if [ "${_waited}" -ge 60 ]; then
      echo "no default route after 60s — giving up" >&2
      exit 1
    fi
    echo "waiting for default route... (${_waited}s)" >&2
    sleep 5
    _waited=$((_waited + 5))
  done
fi

if [ "${MODE}" = on ] && [ ! -d "/sys/class/net/${IFACE}/wireless" ]; then
  echo "default route is on ${IFACE} (not Wi-Fi) — autocake is for Wi-Fi links only" >&2
  exit 0
fi

# --- algorithmic constants (not link-specific tuning) ---
# Download backends. Format: "URL [SIZE_BYTES]" — size omitted means
# byte-precise template; size present means HTTP Range mirror.
# One entry per ASN; see README.md § "How it works" for pool design rationale.
DOWNLOAD_BACKENDS=(
  "https://speed.cloudflare.com/__down?bytes=%BYTES%"
  "https://proof.ovh.net/files/1Gb.dat 1073741824"
  "https://fsn1-speed.hetzner.com/1GB.bin 1073741824"
  "https://speedtest.us-east-1.linodeobjects.com/1GB_test.file 1073741824"
  "https://fra-de-ping.vultr.com/vultr.com.1000MB.bin 1048576000"
  "https://ipv4.scaleway.testdebit.info/1G.iso 1073741824"
)
# Populated by probe_download_backends. Each entry "url|max_bytes" where
# max_bytes=0 marks a byte-precise template URL, and >0 marks a fixed-size
# mirror to be loaded with HTTP Range up to that ceiling.
WORKING_DOWNLOAD_BACKENDS=()
SPEEDTEST_UP_URL="https://speed.cloudflare.com/__up"
# Latency probe backends, tried in order. Connectivity-check endpoints come
# first (high-frequency polling safe); Cloudflare last (regional blocks).
LATENCY_BACKENDS=(
  "https://www.google.com/generate_204"
  "http://detectportal.firefox.com/success.txt"
  "https://captive.apple.com/hotspot-detect.html"
  "https://speed.cloudflare.com/__down?bytes=0"
)
LATENCY_URL=""
STREAMS=3
DOWN_BYTES=25000000
UP_BYTES=15000000
LOAD_DURATION_SEC=8
LOAD_BYTES_MIN=30000000
LOAD_BYTES_MAX=1000000000 # aggregate ceiling; LOAD_TIMEOUT bounds runtime
CURL_TIMEOUT=20
LOAD_TIMEOUT=12
LATENCY_TIMEOUT=10
# besteffort intentional — see CLAUDE.md. wash on ingress: ISP DSCP marks
# aren't trustworthy for tin selection regardless of egress mode.
CAKE_OPTS="besteffort"
CAKE_INGRESS_OPTS="besteffort wash"
# Project-namespaced ifb (12 chars; under IFNAMSIZ=15): `ip link del` won't
# destroy a foreign ifb0, and `ip link add` EEXIST won't silently reuse one.
IFB_DEV="ifb-autocake"
MIN_MBIT=5
STREAMING_GREAT_FLOOR=100   # Cloudflare's Streaming-Great download spec (Mbit)
STREAMING_FLOOR_HEADROOM=10 # only enforce floor when DL exceeds it by this
STEP_PCTS="92 80 65 50 35"
FAIL_PCT_CEILING=95
REFINE_ITERS=4
IDLE_BURSTS=3
IDLE_BURST_SAMPLES=8
LOADED_SAMPLES_LOW=13  # 12 effective post-handshake-discard, for clean links
LOADED_SAMPLES_HIGH=25 # 24 effective post-handshake-discard, for noisy links
JITTER_LOW_MS=4
JITTER_HIGH_MS=10
THRESHOLD_EXTRA_MIN_MS=8  # cake can deliver this on a clean link
THRESHOLD_EXTRA_MAX_MS=25 # beyond this is bufferbloat regardless of jitter
JITTER_THRESHOLD_MULT=2   # threshold extra = mult * idle_jitter, clamped
GREAT_JITTER_MS=30        # Cloudflare AIM "Great" loaded-jitter ceiling
JITTER_GATE_OFF=99999     # sentinel: jitter check disabled on noisy links

# Probe each entry in LATENCY_BACKENDS in order; first that returns 200
# or 204 to a small request becomes active for all latency probes.
select_latency_backend() {
  local url code
  for url in "${LATENCY_BACKENDS[@]}"; do
    # curl always writes "000" on connection failure via -w, but also exits
    # non-zero — without `|| true` the failure would be lost; without the
    # post-substitution :- the code field would double up to "000000".
    code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "${url}" 2> /dev/null || true)
    code="${code:-000}"
    echo "  probe: ${url} → ${code}" >&2
    if [ "${code}" = "200" ] || [ "${code}" = "204" ]; then
      LATENCY_URL="${url}"
      return 0
    fi
  done
  return 1
}

# Probe every entry in DOWNLOAD_BACKENDS in parallel; populate
# WORKING_DOWNLOAD_BACKENDS preserving order (so round-robin is deterministic).
# Probes overlap so total startup cost is one timeout regardless of pool size.
# Returns 0 if at least one backend works.
probe_download_backends() {
  WORKING_DOWNLOAD_BACKENDS=()
  local probe_dir="${WORKDIR}/probe"
  mkdir -p "${probe_dir}"
  local i n="${#DOWNLOAD_BACKENDS[@]}"
  local entry url size
  local pids=()
  for ((i = 0; i < n; i++)); do
    entry="${DOWNLOAD_BACKENDS[i]}"
    url="${entry%% *}"
    size="${entry#* }"
    [ "${size}" = "${entry}" ] && size=0
    # Subshell scopes probe_url and code per-backend (full fork, no
    # leakage to the parent); results are written to indexed files and
    # replayed in order after `wait` so output and the working-pool
    # array follow DOWNLOAD_BACKENDS order regardless of which probe
    # finishes first.
    (
      case "${url}" in
      *%BYTES%*)
        probe_url="${url//%BYTES%/100000}"
        code=$(curl -s -o /dev/null --max-time 6 -w '%{http_code}' "${probe_url}" 2> /dev/null || true)
        code="${code:-000}"
        echo "  probe: ${url%%/__*}/__down?bytes=100000 → ${code}" > "${probe_dir}/${i}.log"
        if [ "${code}" = "200" ]; then
          echo "${url}|0" > "${probe_dir}/${i}.ok"
        fi
        ;;
      *)
        code=$(curl -s -o /dev/null --max-time 6 -r 0-99999 -w '%{http_code}' "${url}" 2> /dev/null || true)
        code="${code:-000}"
        echo "  probe: ${url} (Range 0-99999) → ${code}" > "${probe_dir}/${i}.log"
        if [ "${code}" = "206" ] || [ "${code}" = "200" ]; then
          echo "${url}|${size}" > "${probe_dir}/${i}.ok"
        fi
        ;;
      esac
    ) &
    pids+=($!)
  done
  # Wait on the captured probe PIDs only — bare `wait` would also block
  # on any unrelated background jobs the caller has in flight if this
  # function is ever called outside of startup.
  wait "${pids[@]}"
  for ((i = 0; i < n; i++)); do
    [ -s "${probe_dir}/${i}.log" ] && cat "${probe_dir}/${i}.log" >&2
    [ -s "${probe_dir}/${i}.ok" ] && WORKING_DOWNLOAD_BACKENDS+=("$(< "${probe_dir}/${i}.ok")")
  done
  rm -rf "${probe_dir}"
  [ "${#WORKING_DOWNLOAD_BACKENDS[@]}" -gt 0 ]
}

# Resolve the round-robin backend for stream index $1 into url + max_bytes
# globals. Done in-place (not a subshell) so the next curl call can fire
# in the background and reach the parent's pid table directly.
_pick_url=""
_pick_max=0
pick_download_backend() {
  local idx="${1}"
  local count="${#WORKING_DOWNLOAD_BACKENDS[@]}"
  local entry="${WORKING_DOWNLOAD_BACKENDS[idx % count]}"
  _pick_url="${entry%|*}"
  _pick_max="${entry##*|}"
}

# Background-fire one download stream against the round-robin backend
# selected by stream index $4. Pass an empty wfmt for pure-load streams
# (the loaded probe doesn't read per-stream output); pass a speed/code
# format string for measurement runs.
download_bg() {
  local out="$1" bytes="$2" timeout="$3" idx="$4" wfmt="$5"
  pick_download_backend "${idx}"
  local args=(-s -o /dev/null --max-time "${timeout}")
  [ -n "${wfmt}" ] && args+=(-w "${wfmt}")
  if [ "${_pick_max}" = "0" ]; then
    curl "${args[@]}" "${_pick_url//%BYTES%/${bytes}}" > "${out}" &
  else
    [ "${bytes}" -gt "${_pick_max}" ] && bytes="${_pick_max}"
    args+=(-r "0-$((bytes - 1))")
    curl "${args[@]}" "${_pick_url}" > "${out}" &
  fi
}

# Background-fire one upload stream against SPEEDTEST_UP_URL. Symmetric to
# download_bg. Process substitution (not a pipe subshell) keeps curl as the
# direct background child so $! is curl's PID and on_interrupt reaches it.
# Upload is single-mirror: no public pool of unauthenticated POST endpoints
# exists to round-robin across.
upload_bg() {
  local out="$1" bytes="$2" timeout="$3" wfmt="$4"
  local args=(-s -o /dev/null --max-time "${timeout}" -X POST --data-binary @-)
  [ -n "${wfmt}" ] && args+=(-w "${wfmt}")
  curl "${args[@]}" "${SPEEDTEST_UP_URL}" < <(head -c "${bytes}" /dev/zero) > "${out}" &
}

# Reap a list of background PIDs without aborting on already-exited ones.
wait_all() {
  local pid
  for pid in "$@"; do wait "${pid}" 2> /dev/null || true; done
}

# sqm_off [iface] — tear down cake on iface (default: $IFACE) and remove the
# project-namespaced ifb device. Iface arg lets cleanup target the previously
# shaped device when the default route has shifted since apply time.
sqm_off() {
  local iface="${1:-${IFACE:-}}"
  if [ -n "${iface}" ]; then
    tc qdisc del dev "${iface}" ingress 2> /dev/null || true
    tc qdisc del dev "${iface}" root 2> /dev/null || true
  fi
  tc qdisc del dev "${IFB_DEV}" root 2> /dev/null || true
  ip link del "${IFB_DEV}" 2> /dev/null || true
}

sqm_apply() {
  local up_cap="${1}" down_cap="${2}"
  # Critical commands are checked explicitly: we run under `set -uo
  # pipefail` (no -e), so a silent failure here would let try_pct
  # measure latency on an unshaped link and report a false pass. The
  # preflight (cake on lo) catches the common kernel/iproute2 case, but
  # ifb-module load failures and tc surprises (broken qdisc-replace
  # races, hardware offload conflicts) only surface at apply time.
  # On any failure, exit non-zero — the EXIT trap runs sqm_off because
  # SQM_COMMITTED is still 0, so we leave clean kernel state behind.
  modprobe ifb 2> /dev/null || true
  ip link add "${IFB_DEV}" type ifb 2> /dev/null || true
  ip link set dev "${IFB_DEV}" up || {
    echo "ERROR: cannot bring ${IFB_DEV} up — ifb support unavailable?" >&2
    exit 1
  }
  # shellcheck disable=SC2086
  tc qdisc replace dev "${IFACE}" root cake bandwidth "${up_cap}Mbit" ${CAKE_OPTS} || {
    echo "ERROR: cake egress qdisc apply failed on ${IFACE}" >&2
    exit 1
  }
  tc qdisc replace dev "${IFACE}" handle ffff: ingress || {
    echo "ERROR: ingress qdisc apply failed on ${IFACE}" >&2
    exit 1
  }
  # The redirect filter is one-shot per ingress qdisc: pinning pref +
  # handle keeps it from accumulating across the search's many sqm_apply
  # calls (without those, a 10-iteration search leaves 10 stacked
  # filters). The kernel can't atomically `replace` a matchall+mirred
  # filter, so the second and later calls return EEXIST — that's
  # harmless (the original filter is still installed and still pointing
  # at ifb-autocake) but noisy, hence the stderr suppression.
  tc filter replace dev "${IFACE}" parent ffff: pref 10 handle 0x1 \
    protocol all matchall action mirred egress redirect dev "${IFB_DEV}" \
    2> /dev/null || true
  # shellcheck disable=SC2086
  tc qdisc replace dev "${IFB_DEV}" root cake bandwidth "${down_cap}Mbit" ${CAKE_INGRESS_OPTS} || {
    echo "ERROR: cake ingress qdisc apply failed on ${IFB_DEV}" >&2
    exit 1
  }
}

WORKDIR=$(mktemp -d) || {
  echo "ERROR: mktemp -d failed" >&2
  exit 1
}
# SQM_COMMITTED=0 keeps the EXIT trap in rollback mode until the final apply
# succeeds. on_interrupt calls sqm_off explicitly for message ordering; EXIT
# path is idempotent.
SQM_COMMITTED=0
on_interrupt() {
  echo
  echo "Interrupted — disabling SQM"
  local pids
  pids=$(jobs -p)
  # shellcheck disable=SC2086
  [ -n "${pids}" ] && kill ${pids} 2> /dev/null
  sqm_off
  exit 130
}
exit_cleanup() {
  rm -rf "${WORKDIR:-}"
  [ "${SQM_COMMITTED:-0}" -eq 1 ] || sqm_off
}
trap exit_cleanup EXIT
trap on_interrupt INT TERM HUP

# HTTP request-response time stats over LATENCY_URL.
# Uses one curl invocation with --next so the TLS connection is reused;
# discards the first sample (handshake overhead) and computes percentiles
# over the rest. Echoes "P75_ms JITTER_ms" where JITTER = P95 - P25.
http_latency_stats() {
  local count="${1}"
  # --max-time must be set on every --next request: curl resets options
  # at each --next, so a single timeout on the head only protects the
  # first request. Without per-request timeouts, a stalled request later
  # in the chain produces no time_total output and sinks the whole probe.
  local args=()
  local i
  for ((i = 1; i <= count; i++)); do
    [ "${i}" -gt 1 ] && args+=(--next)
    args+=(-s -o /dev/null --max-time "${LATENCY_TIMEOUT}" -w '%{time_total}\n' "${LATENCY_URL}")
  done
  # Drop the first sample (TLS handshake) and any sample that reached the
  # per-request --max-time (curl still emits time_total ≈ LATENCY_TIMEOUT
  # on timeout; without the LIMIT filter, two timed-out samples poison
  # P95 by inflating it to the timeout value).
  curl "${args[@]}" 2> /dev/null |
    tail -n +2 |
    sort -n -k1 |
    awk -v LIMIT="${LATENCY_TIMEOUT}" '
        BEGIN { LIMIT = LIMIT * 0.95 }
        { if ($1 + 0 < LIMIT) v[++n] = $1 + 0 }
        END {
          if (n == 0) { print "0 0"; exit }
          p25 = int((n * 0.25) + 0.5); if (p25 < 1) p25 = 1
          p75 = int((n * 0.75) + 0.5); if (p75 < 1) p75 = 1; if (p75 > n) p75 = n
          p95 = int((n * 0.95) + 0.5); if (p95 < 1) p95 = 1; if (p95 > n) p95 = n
          printf "%.0f %.0f\n", v[p75] * 1000, (v[p95] - v[p25]) * 1000
        }
      '
}

# IDLE_BURSTS bursts of IDLE_BURST_SAMPLES; echoes the median burst's "P75 JITTER".
idle_baseline() {
  local i p75 jit pairs=""
  for ((i = 1; i <= IDLE_BURSTS; i++)); do
    read -r p75 jit < <(http_latency_stats "${IDLE_BURST_SAMPLES}")
    [ -n "${p75:-}" ] && [ "${p75}" -gt 0 ] || continue
    pairs="${pairs}${p75} ${jit}"$'\n'
    [ "${i}" -lt "${IDLE_BURSTS}" ] && sleep 1
  done
  if [ -z "${pairs}" ]; then
    echo "0 0"
    return
  fi
  # Sort pairs by P75; pick the median row. With odd burst counts the
  # middle is unambiguous; with even counts we take the lower median,
  # which biases slightly toward the cleaner observation.
  printf '%s' "${pairs}" | sort -n -k1 | awk '
    { rows[NR] = $0 }
    END {
      mid = int((NR + 1) / 2)
      if (mid < 1) mid = 1
      print rows[mid]
    }
  '
}

measure_parallel() {
  local dir="${1}" bytes="${2}" streams="${3}"
  local pids=()
  local i
  for ((i = 1; i <= streams; i++)); do
    if [ "${dir}" = down ]; then
      download_bg "${WORKDIR}/s${i}" "${bytes}" "${CURL_TIMEOUT}" "$((i - 1))" '%{speed_download} %{http_code}\n'
    else
      upload_bg "${WORKDIR}/s${i}" "${bytes}" "${CURL_TIMEOUT}" '%{speed_upload} %{http_code}\n'
    fi
    pids+=("$!")
  done
  wait_all "${pids[@]}"

  local total_bps=0 bps http codes=""
  for ((i = 1; i <= streams; i++)); do
    read -r bps http < "${WORKDIR}/s${i}" 2> /dev/null || {
      bps=0
      http=0
    }
    codes="${codes}${codes:+,}${http:-curl-fail}"
    # 200 = full body (Cloudflare template), 206 = Partial Content (Range mirror)
    # %.0f keeps the running sum in plain decimal: awk's default `print`
    # would switch to %.6g (e.g. "1.23e+08") above ~1e7, which then has
    # to be re-parsed by the next awk and is also locale-sensitive on
    # systems where LC_NUMERIC uses a comma decimal mark.
    if [ "${http:-0}" = 200 ] || [ "${http:-0}" = 206 ]; then
      total_bps=$(awk -v t="${total_bps}" -v b="${bps:-0}" 'BEGIN{printf "%.0f", t+b}')
    fi
    rm -f "${WORKDIR}/s${i}"
  done
  # Surface per-stream HTTP codes when no stream succeeded so the caller's
  # error message points at why (rate limit / CDN error / curl failure).
  [ "${total_bps}" = 0 ] && echo "[${dir}: HTTP codes ${codes}]" >&2
  awk -v b="${total_bps}" 'BEGIN{printf "%d", (b*8/1e6) + 0.5}'
}

# Per-stream bytes so STREAMS streams together sustain LOAD_DURATION_SEC at
# cap_mbit aggregate, with absolute clamps applied at the aggregate level.
# Ceiling division so 3 streams target the full cap, not cap-2 Mbit.
load_bytes_per_stream() {
  local cap_mbit="${1}"
  local per_stream_mbit=$(((cap_mbit + STREAMS - 1) / STREAMS))
  [ "${per_stream_mbit}" -lt 1 ] && per_stream_mbit=1
  local bytes=$((per_stream_mbit * 125000 * LOAD_DURATION_SEC))
  local floor=$((LOAD_BYTES_MIN / STREAMS))
  local ceiling=$((LOAD_BYTES_MAX / STREAMS))
  [ "${bytes}" -lt "${floor}" ] && bytes="${floor}"
  [ "${bytes}" -gt "${ceiling}" ] && bytes="${ceiling}"
  echo "${bytes}"
}

# Generate bidirectional load with STREAMS parallel streams per direction,
# return "P75_ms JITTER_ms" under load.
#
# Liveness check before sampling: streams can finish early (fast cap) or 429
# out (rate-limited backend), either draining the queue for a false-pass read.
# Require alive ≥ STREAMS-1: tolerates one dropout without making every cap
# unmeasurable, but still rejects the 1-of-3 partial-drain case.
loaded_latency_bidir() {
  local down_cap="${1}" up_cap="${2}"
  local down_bytes up_bytes
  down_bytes=$(load_bytes_per_stream "${down_cap}")
  up_bytes=$(load_bytes_per_stream "${up_cap}")

  local down_pids=() up_pids=()
  local i
  for ((i = 1; i <= STREAMS; i++)); do
    download_bg /dev/null "${down_bytes}" "${LOAD_TIMEOUT}" "$((i - 1))" ''
    down_pids+=("$!")
    upload_bg /dev/null "${up_bytes}" "${LOAD_TIMEOUT}" ''
    up_pids+=("$!")
  done

  sleep 2

  local alive_down=0 alive_up=0 pid
  for pid in "${down_pids[@]}"; do
    kill -0 "${pid}" 2> /dev/null && alive_down=$((alive_down + 1))
  done
  for pid in "${up_pids[@]}"; do
    kill -0 "${pid}" 2> /dev/null && alive_up=$((alive_up + 1))
  done
  local min_alive=$((STREAMS - 1))
  [ "${min_alive}" -lt 1 ] && min_alive=1
  if [ "${alive_down}" -lt "${min_alive}" ] || [ "${alive_up}" -lt "${min_alive}" ]; then
    wait_all "${down_pids[@]}" "${up_pids[@]}"
    echo "0 0"
    return
  fi

  local lat jit
  read -r lat jit < <(http_latency_stats "${LOADED_SAMPLES}")
  wait_all "${down_pids[@]}" "${up_pids[@]}"
  echo "${lat:-0} ${jit:-0}"
}

# Predicate: true iff (lat, jit) clears both thresholds and the probe
# actually produced samples (lat>0). Single source of truth for the
# pass condition — classify_tag and every gate-check share it.
is_pass() {
  local lat="${1}" jit="${2}"
  [ "${lat}" -gt 0 ] && [ "${lat}" -le "${THRESHOLD_MS}" ] && [ "${jit}" -le "${JITTER_THRESHOLD_MS}" ]
}

# Classify a (lat, jit) pair against the configured thresholds and echo a
# short bracketed tag — PASS / FAIL (latency) / FAIL (jitter) /
# FAIL (latency+jitter) / FAIL (probe stalled). Used by every line that
# reports a measurement so the reader doesn't have to re-derive pass/fail
# from threshold values that vary per run.
classify_tag() {
  local lat="${1}" jit="${2}"
  if [ "${lat}" -le 0 ]; then
    echo "FAIL (probe stalled)"
    return
  fi
  if is_pass "${lat}" "${jit}"; then
    echo "PASS"
    return
  fi
  local lat_bad=0 jit_bad=0
  [ "${lat}" -gt "${THRESHOLD_MS}" ] && lat_bad=1
  [ "${jit}" -gt "${JITTER_THRESHOLD_MS}" ] && jit_bad=1
  if [ "${lat_bad}" -eq 1 ] && [ "${jit_bad}" -eq 1 ]; then
    echo "FAIL (latency+jitter)"
  elif [ "${lat_bad}" -eq 1 ]; then
    echo "FAIL (latency)"
  else
    echo "FAIL (jitter)"
  fi
}

# Print one probe summary line: "<prefix>P75=<lat>ms (≤T) jitter=<jit>ms
# (≤J) [<tag>]". Single format string for every measurement report so the
# search trace, unshaped check, recheck, and fallback recheck all line up.
report_probe() {
  local prefix="${1}" lat="${2}" jit="${3}"
  echo "${prefix}P75=${lat}ms (≤${THRESHOLD_MS}) jitter=${jit}ms (≤${JITTER_THRESHOLD_DISPLAY}) [$(classify_tag "${lat}" "${jit}")]"
}

# try_pct <pct>: apply cake at pct of measured bandwidth, verify under
# bidirectional load. Sets LAST_DOWN/LAST_UP on a real test. Returns:
#   0 — pass (latency and jitter within thresholds)
#   1 — quality fail (latency or jitter over threshold)
#   2 — floor skip (down cap below STREAMING_GREAT_FLOOR with floor enabled)
#   3 — degenerate: cap rounds to 0 Mbit. MIN_MBIT plus the smallest
#       STEP_PCTS rung make this unreachable in practice; the guard is
#       defensive. Distinct from 1 so coarse_pass doesn't add it to
#       QUALITY_FAILED — there's nothing about quality to record.
try_pct() {
  local pct="${1}"
  local down_cap=$((DL * pct / 100))
  local up_cap=$((UL * pct / 100))
  [ "${down_cap}" -ge 1 ] && [ "${up_cap}" -ge 1 ] || return 3

  if [ "${ENFORCE_STREAMING_FLOOR}" -eq 1 ] && [ "${down_cap}" -lt "${STREAMING_GREAT_FLOOR}" ]; then
    echo "  ${pct}% → ${down_cap} Mbit down would drop below Streaming-Great floor (${STREAMING_GREAT_FLOOR}); skipping"
    return 2
  fi

  sqm_apply "${up_cap}" "${down_cap}"
  local lat jit
  read -r lat jit < <(loaded_latency_bidir "${down_cap}" "${up_cap}")

  LAST_DOWN="${down_cap}"
  LAST_UP="${up_cap}"
  LAST_LAT="${lat}"

  # Track the lowest-latency cap seen anywhere in the search, regardless
  # of pass/fail, for the best-effort fallback below.
  if [ "${lat}" -gt 0 ] && [ "${lat}" -lt "${BEST_NEARMISS_LAT}" ]; then
    BEST_NEARMISS_LAT="${lat}"
    BEST_NEARMISS_JIT="${jit}"
    BEST_NEARMISS_PCT="${pct}"
    BEST_NEARMISS_DOWN="${down_cap}"
    BEST_NEARMISS_UP="${up_cap}"
  fi

  report_probe "  ${pct}% → ${down_cap}/${up_cap} Mbit → " "${lat}" "${jit}"
  is_pass "${lat}" "${jit}" && return 0
  return 1
}

# Walk STEP_PCTS and stop on the first passing cap. Sets BEST_PCT/DOWN/UP
# and FAIL_PCT (last failing pct, or FAIL_PCT_CEILING if nothing failed).
# Records caps that failed on quality in QUALITY_FAILED so a streaming-
# floor retry can skip them — they failed for reasons unrelated to the
# floor and won't change just because the floor drops.
coarse_pass() {
  BEST_PCT=0
  BEST_DOWN=0
  BEST_UP=0
  BEST_LAT=0
  FAIL_PCT="${FAIL_PCT_CEILING}"
  local pct rc
  for pct in ${STEP_PCTS}; do
    case " ${QUALITY_FAILED} " in
    *" ${pct} "*)
      echo "  ${pct}% → previously failed quality this run; skipping"
      FAIL_PCT="${pct}"
      continue
      ;;
    esac
    try_pct "${pct}"
    rc=$?
    case "${rc}" in
    0)
      BEST_PCT="${pct}"
      BEST_DOWN="${LAST_DOWN}"
      BEST_UP="${LAST_UP}"
      BEST_LAT="${LAST_LAT}"
      return 0
      ;;
    2 | 3)
      # 2: floor-skipped (the cap might pass on a floor-disabled retry).
      # 3: degenerate cap (no measurement happened).
      # Either way, nothing to record in QUALITY_FAILED.
      FAIL_PCT="${pct}"
      ;;
    *)
      FAIL_PCT="${pct}"
      QUALITY_FAILED="${QUALITY_FAILED} ${pct}"
      ;;
    esac
  done
  return 1
}

# SQM_COMMITTED=1 after teardown so the EXIT trap doesn't re-run sqm_off.
if [ "${MODE}" = off ]; then
  target_iface="${SAVED_IFACE:-${IFACE}}"
  sqm_off "${target_iface}"
  rm -f "${STATE_FILE}"
  SQM_COMMITTED=1
  if [ -n "${target_iface}" ]; then
    echo "autocake SQM removed from ${target_iface}"
  else
    echo "autocake SQM removed (no iface state to clean)"
  fi
  exit 0
fi

# ---------- Main flow ----------

# Initial cleanup: clear any cake state on the current iface, plus the
# iface a previous run shaped if it was different (laptop dock, route
# change). Without this second pass, a wlan0 → eth0 swap between runs
# would leave wlan0's mirred filter pointing at the now-deleted ifb.
sqm_off
if [ -n "${SAVED_IFACE}" ] && [ "${SAVED_IFACE}" != "${IFACE}" ]; then
  sqm_off "${SAVED_IFACE}"
fi
echo "Interface: ${IFACE}"
echo "Selecting latency probe backend..."
if ! select_latency_backend; then
  echo "ERROR: no latency probe backend reachable — every endpoint failed." >&2
  exit 1
fi
echo "  using: ${LATENCY_URL}"
echo "Measuring unloaded idle latency (${IDLE_BURSTS} bursts × ${IDLE_BURST_SAMPLES} samples)..."
read -r IDLE IDLE_JITTER < <(idle_baseline)
IDLE="${IDLE:-0}"
IDLE_JITTER="${IDLE_JITTER:-0}"
echo "  idle P75: ${IDLE}ms   idle jitter (P95-P25): ${IDLE_JITTER}ms"

if [ "${IDLE}" -le 0 ]; then
  echo "ERROR: idle latency probe failed — ${LATENCY_URL} unreachable?" >&2
  exit 1
fi

# Adaptive: more samples on noisier links so P75 stays meaningful.
if [ "${IDLE_JITTER}" -gt "${JITTER_HIGH_MS}" ]; then
  LOADED_SAMPLES="${LOADED_SAMPLES_HIGH}"
elif [ "${IDLE_JITTER}" -lt "${JITTER_LOW_MS}" ]; then
  LOADED_SAMPLES="${LOADED_SAMPLES_LOW}"
else
  LOADED_SAMPLES=$(((LOADED_SAMPLES_LOW + LOADED_SAMPLES_HIGH) / 2))
fi

THRESHOLD_EXTRA_MS=$((IDLE_JITTER * JITTER_THRESHOLD_MULT))
[ "${THRESHOLD_EXTRA_MS}" -lt "${THRESHOLD_EXTRA_MIN_MS}" ] && THRESHOLD_EXTRA_MS="${THRESHOLD_EXTRA_MIN_MS}"
[ "${THRESHOLD_EXTRA_MS}" -gt "${THRESHOLD_EXTRA_MAX_MS}" ] && THRESHOLD_EXTRA_MS="${THRESHOLD_EXTRA_MAX_MS}"
THRESHOLD_MS=$((IDLE + THRESHOLD_EXTRA_MS))

if [ "${IDLE_JITTER}" -ge "${GREAT_JITTER_MS}" ]; then
  JITTER_THRESHOLD_MS="${JITTER_GATE_OFF}"
  JITTER_THRESHOLD_DISPLAY="off; idle jitter ${IDLE_JITTER}ms ≥ ${GREAT_JITTER_MS}ms"
else
  JITTER_THRESHOLD_MS="${GREAT_JITTER_MS}"
  JITTER_THRESHOLD_DISPLAY="${JITTER_THRESHOLD_MS}ms"
fi

echo "  loaded latency threshold: idle + ${THRESHOLD_EXTRA_MS}ms = ${THRESHOLD_MS}ms"
echo "  loaded jitter threshold:  ${JITTER_THRESHOLD_DISPLAY}"
echo "  loaded samples per probe: ${LOADED_SAMPLES}"

echo "Probing download backends..."
if ! probe_download_backends; then
  echo "ERROR: no download backend reachable — every mirror failed the probe." >&2
  exit 1
fi
echo "  pool: ${#WORKING_DOWNLOAD_BACKENDS[@]} of ${#DOWNLOAD_BACKENDS[@]} backends responded"
for _entry in "${WORKING_DOWNLOAD_BACKENDS[@]}"; do
  echo "    ${_entry%|*}"
done
# Cap STREAMS at pool size so round-robin gives each backend at most one
# stream. With STREAMS=3 and a 2-backend pool, the original code would
# send streams 0+2 to backend 0 — Cloudflare's pattern is to 429 under
# that sustained 2-stream load, which then cascades into every loaded
# probe stalling. One-stream-per-backend keeps individual mirror load
# below their rate-limit thresholds.
if [ "${#WORKING_DOWNLOAD_BACKENDS[@]}" -lt "${STREAMS}" ]; then
  echo "  STREAMS reduced from ${STREAMS} to ${#WORKING_DOWNLOAD_BACKENDS[@]} (one stream per backend; avoids double-loading any single mirror)"
  STREAMS="${#WORKING_DOWNLOAD_BACKENDS[@]}"
fi
if [ "${STREAMS}" -eq 1 ]; then
  echo "  WARNING: single-stream probe — on fast links the queue may not stay full,"
  echo "    so the latency reading can falsely look idle. Re-run when more mirrors are reachable."
fi
echo "Measuring sustained throughput (${STREAMS} parallel streams per direction, distributed across pool)..."
DL=$(measure_parallel down "${DOWN_BYTES}" "${STREAMS}")
UL=$(measure_parallel up "${UP_BYTES}" "${STREAMS}")
echo "  down: ${DL} Mbit (aggregate of ${STREAMS} streams)"
echo "  up:   ${UL} Mbit (aggregate of ${STREAMS} streams)"

if [ "${DL:-0}" -lt "${MIN_MBIT}" ] || [ "${UL:-0}" -lt "${MIN_MBIT}" ]; then
  echo "ERROR: throughput measurement failed (down=${DL} up=${UL}) — leaving unshaped" >&2
  exit 1
fi

# Streaming-Great floor only kicks in if the link has comfortable headroom.
if [ "${DL}" -ge $((STREAMING_GREAT_FLOOR + STREAMING_FLOOR_HEADROOM)) ]; then
  ENFORCE_STREAMING_FLOOR=1
  echo "  enforcing Streaming-Great floor: down cap ≥ ${STREAMING_GREAT_FLOOR} Mbit"
else
  ENFORCE_STREAMING_FLOOR=0
fi

echo "Target: loaded latency ≤ ${THRESHOLD_MS}ms under bidirectional load"

# Shape-or-skip: if the unshaped link already meets both gates, installing
# any cap would just throttle for no win. SQM was already cleared at the
# top of the run, so this measures the genuine unshaped behavior.
echo "Testing unshaped link under bidirectional load..."
read -r UNSHAPED_LAT UNSHAPED_JIT < <(loaded_latency_bidir "${DL}" "${UL}")
report_probe "  unshaped: " "${UNSHAPED_LAT}" "${UNSHAPED_JIT}"
if is_pass "${UNSHAPED_LAT}" "${UNSHAPED_JIT}"; then
  echo "SQM not needed — link already meets thresholds unshaped. Leaving off."
  exit 0
fi

# Coarse pass: walk the step ladder until one passes.
# QUALITY_FAILED accumulates space-delimited integer pcts; the membership
# test in coarse_pass (`case " ${QUALITY_FAILED} " in *" ${pct} "*)`)
# pads with spaces on both ends so e.g. "5" doesn't match inside "35".
# The current STEP_PCTS values (35/50/65/80/92) have no substring
# overlap, but if you add overlapping values (5, 50, 500) the format is
# still safe — don't switch to a non-space delimiter or to bare
# concatenation without re-checking the match.
QUALITY_FAILED=""
BEST_NEARMISS_LAT=999999
BEST_NEARMISS_JIT=999999
BEST_NEARMISS_PCT=0
BEST_NEARMISS_DOWN=0
BEST_NEARMISS_UP=0
coarse_pass || true

# If the streaming-great floor caused all caps to be skipped, retry without it.
if [ "${BEST_PCT}" -eq 0 ] && [ "${ENFORCE_STREAMING_FLOOR}" -eq 1 ]; then
  echo "Streaming-Great floor blocked every passing cap; retrying without floor..."
  ENFORCE_STREAMING_FLOOR=0
  coarse_pass || true
fi

BEST_EFFORT=0
if [ "${BEST_PCT}" -eq 0 ] && [ "${BEST_NEARMISS_LAT}" -lt 999999 ] && [ "${UNSHAPED_LAT}" -gt 0 ]; then
  IMPROVEMENT=$((UNSHAPED_LAT - BEST_NEARMISS_LAT))
  if [ "${IMPROVEMENT}" -gt $((UNSHAPED_LAT / 3)) ]; then
    echo "No cap met strict thresholds; applying ${BEST_NEARMISS_PCT}% as best-effort."
    echo "  unshaped P75 ${UNSHAPED_LAT}ms → ${BEST_NEARMISS_PCT}% gives ${BEST_NEARMISS_LAT}ms (jitter ${BEST_NEARMISS_JIT}ms)"
    echo "  link RF conditions limit Cloudflare 'Great' scoring; cake still cuts real-world bloat substantially"
    BEST_PCT="${BEST_NEARMISS_PCT}"
    BEST_DOWN="${BEST_NEARMISS_DOWN}"
    BEST_UP="${BEST_NEARMISS_UP}"
    BEST_LAT="${BEST_NEARMISS_LAT}"
    BEST_EFFORT=1
  fi
fi

if [ "${BEST_PCT}" -eq 0 ]; then
  echo "No cap produced acceptable loaded latency — leaving SQM off." >&2
  sqm_off
  exit 1
fi

# Snapshot the pre-refine winner. If refine then advances BEST_PCT upward
# and the recheck below rejects it, this is the rung we step back to —
# it's already passed once, so it's a real fallback rather than an
# arbitrary distance off the refined value.
ORIG_COARSE_PCT="${BEST_PCT}"

# Refine: binary-search upward between BEST_PCT (passing) and FAIL_PCT (failing,
# or the ceiling if nothing failed above).
if [ "${FAIL_PCT}" -gt "${BEST_PCT}" ]; then
  echo "Refining between ${BEST_PCT}% and ${FAIL_PCT}% (up to ${REFINE_ITERS} iterations)..."
  LO="${BEST_PCT}"
  HI="${FAIL_PCT}"
  for ((_iter = 1; _iter <= REFINE_ITERS; _iter++)); do
    MID=$(((LO + HI) / 2))
    [ "${MID}" -le "${LO}" ] && break
    if try_pct "${MID}"; then
      BEST_PCT="${MID}"
      BEST_DOWN="${LAST_DOWN}"
      BEST_UP="${LAST_UP}"
      BEST_LAT="${LAST_LAT}"
      LO="${MID}"
    else
      HI="${MID}"
    fi
  done
fi

echo "Re-verifying stability at ${BEST_PCT}%..."
sqm_apply "${BEST_UP}" "${BEST_DOWN}"
read -r RECHECK_LAT RECHECK_JIT < <(loaded_latency_bidir "${BEST_DOWN}" "${BEST_UP}")
report_probe "  recheck: " "${RECHECK_LAT}" "${RECHECK_JIT}"
USED_STEPDOWN=0
UNSTABLE_COMMIT=0
if [ "${BEST_EFFORT}" -eq 1 ]; then
  echo "  best-effort cap; strict recheck skipped (link can't meet 'Great' thresholds anyway)"
elif is_pass "${RECHECK_LAT}" "${RECHECK_JIT}"; then
  echo "  stable"
else
  # Prefer falling back to the coarse-pass winner if refine moved us
  # above it — that rung passed once already, so it's a real candidate.
  # Otherwise drop a small heuristic step (refine never advanced past
  # coarse, so there's no prior passing rung to retreat to).
  if [ "${BEST_PCT}" -gt "${ORIG_COARSE_PCT}" ]; then
    FALLBACK_PCT="${ORIG_COARSE_PCT}"
  else
    FALLBACK_PCT=$((BEST_PCT - 5))
  fi
  if [ "${FALLBACK_PCT}" -ge 30 ]; then
    echo "  not stable — stepping down to ${FALLBACK_PCT}%"
    try_pct "${FALLBACK_PCT}"
    rc=$?
    case "${rc}" in
    0)
      # Double-check the fallback before committing — the same transient
      # variance that broke the original recheck could have produced a
      # false-pass on the step-down. try_pct already left the cap installed.
      read -r FB_LAT FB_JIT < <(loaded_latency_bidir "${LAST_DOWN}" "${LAST_UP}")
      report_probe "  fallback recheck: " "${FB_LAT}" "${FB_JIT}"
      if is_pass "${FB_LAT}" "${FB_JIT}"; then
        BEST_PCT="${FALLBACK_PCT}"
        BEST_DOWN="${LAST_DOWN}"
        BEST_UP="${LAST_UP}"
        BEST_LAT="${FB_LAT}"
        RECHECK_LAT="${FB_LAT}"
        RECHECK_JIT="${FB_JIT}"
        USED_STEPDOWN=1
        echo "  fallback stable"
      else
        echo "  fallback also unstable — keeping ${BEST_PCT}% (link may be transient)"
        UNSTABLE_COMMIT=1
      fi
      ;;
    2)
      # Floor blocks the fallback rung. The original recheck still failed,
      # so the committed cap is genuinely unstable — the floor only tells
      # us we can't legally try lower, not that the cap is good.
      echo "  fallback rung below Streaming-Great floor — keeping ${BEST_PCT}%"
      UNSTABLE_COMMIT=1
      ;;
    *)
      echo "  step-down probe also failed — keeping ${BEST_PCT}% (link may be transient)"
      UNSTABLE_COMMIT=1
      ;;
    esac
  else
    echo "  not stable but already at floor — keeping ${BEST_PCT}%"
    UNSTABLE_COMMIT=1
  fi
fi

# Confidence label: pure synthesis of already-collected signals, no extra probing.
#   + idle jitter      + pool size      + recheck delta      + which path won
CONF_SCORE=0
CONF_NOTES=()
if [ "${IDLE_JITTER}" -le "${JITTER_LOW_MS}" ]; then
  CONF_SCORE=$((CONF_SCORE + 1))
elif [ "${IDLE_JITTER}" -ge "${JITTER_HIGH_MS}" ]; then
  CONF_SCORE=$((CONF_SCORE - 1))
  CONF_NOTES+=("noisy idle baseline (jitter ${IDLE_JITTER}ms)")
fi
POOL_SIZE="${#WORKING_DOWNLOAD_BACKENDS[@]}"
if [ "${POOL_SIZE}" -ge 2 ]; then
  CONF_SCORE=$((CONF_SCORE + 1))
else
  CONF_SCORE=$((CONF_SCORE - 1))
  CONF_NOTES+=("only 1 download backend in pool")
fi
# Recheck-vs-search delta: rewards consistency only when the recheck
# actually passed. Two failing samples that happen to agree aren't
# evidence the cap is good — they're evidence the cap is consistently
# bad. The drift penalty applies regardless: large run-to-run swings
# always reduce confidence.
if [ "${BEST_LAT:-0}" -gt 0 ] && [ "${RECHECK_LAT:-0}" -gt 0 ]; then
  RECHECK_DELTA=$((RECHECK_LAT - BEST_LAT))
  [ "${RECHECK_DELTA}" -lt 0 ] && RECHECK_DELTA=$((-RECHECK_DELTA))
  if [ "${RECHECK_DELTA}" -le 3 ] && is_pass "${RECHECK_LAT}" "${RECHECK_JIT}"; then
    CONF_SCORE=$((CONF_SCORE + 1))
  elif [ "${RECHECK_DELTA}" -ge 8 ]; then
    CONF_SCORE=$((CONF_SCORE - 1))
    CONF_NOTES+=("recheck drifted ${RECHECK_DELTA}ms vs search probe")
  fi
fi
if [ "${BEST_EFFORT:-0}" -eq 1 ]; then
  CONF_SCORE=$((CONF_SCORE - 2))
  CONF_NOTES+=("best-effort cap (link can't reach Cloudflare 'Great')")
elif [ "${UNSTABLE_COMMIT:-0}" -eq 1 ]; then
  CONF_SCORE=$((CONF_SCORE - 2))
  CONF_NOTES+=("final cap failed stability rechecks")
elif [ "${USED_STEPDOWN}" -eq 1 ]; then
  CONF_SCORE=$((CONF_SCORE - 1))
  CONF_NOTES+=("step-down used after recheck instability")
fi
if [ "${CONF_SCORE}" -ge 2 ]; then
  CONFIDENCE="high"
elif [ "${CONF_SCORE}" -ge 0 ]; then
  CONFIDENCE="medium"
else
  CONFIDENCE="low"
fi

# Refinement / fallback may have left a different cap active; re-apply best.
sqm_apply "${BEST_UP}" "${BEST_DOWN}"
SQM_COMMITTED=1
# Best-effort: a write failure here doesn't undo the successful apply.
{
  printf 'iface=%s\n' "${IFACE}"
  printf 'ifb=%s\n' "${IFB_DEV}"
  printf 'pct=%s\n' "${BEST_PCT}"
  printf 'down_mbit=%s\n' "${BEST_DOWN}"
  printf 'up_mbit=%s\n' "${BEST_UP}"
  printf 'applied_at=%s\n' "$(date -u +%FT%TZ)"
} > "${STATE_FILE}" 2> /dev/null || true
echo "SQM ON at ${BEST_PCT}% — DOWN=${BEST_DOWN}Mbit UP=${BEST_UP}Mbit  [confidence: ${CONFIDENCE} (${CONF_SCORE})]"
if [ "${#CONF_NOTES[@]}" -gt 0 ]; then
  for _note in "${CONF_NOTES[@]}"; do
    echo "  note: ${_note}"
  done
fi
