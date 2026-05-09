#!/bin/bash
# autocake — fully automated SQM (cake) bandwidth tuner.
#
# Measures your link, picks the cap that keeps latency under load within an
# adaptive margin of idle, applies cake, and verifies the result. Zero flags,
# zero env vars, zero per-rig tuning constants.
#
# Usage: sudo ./autocake.sh    (run from the repo directory)
#
# See README.md for the algorithm, requirements, and limitations.

set -uo pipefail

if [ "${EUID}" -ne 0 ]; then exec sudo -- "${0}" "${@}"; fi

for cmd in tc curl ip awk head flock modprobe; do
  command -v "${cmd}" > /dev/null 2>&1 || {
    echo "missing dependency: ${cmd}" >&2
    exit 1
  }
done

# Preflight: cake qdisc support. Probes by attaching a no-op cake qdisc to
# the loopback interface (and removing it immediately). Catches the kernel
# module (sch_cake, mainlined in 4.19) and the iproute2 'cake' keyword
# (added in 4.19) in one shot. Failing here surfaces the unsupported-kernel
# case before any measurement work.
modprobe sch_cake 2> /dev/null || true
if ! tc qdisc replace dev lo root cake 2> /dev/null; then
  echo "ERROR: cake qdisc unsupported on this system." >&2
  echo "  Need: Linux >= 4.19 with CONFIG_NET_SCH_CAKE, iproute2 >= 4.19." >&2
  exit 1
fi
tc qdisc del dev lo root 2> /dev/null || true

# Preflight: curl --next, used by the latency probe to reuse a single TLS
# connection across samples. Added in curl 7.36 (March 2014).
if ! curl --help all 2> /dev/null | grep -q -- '--next'; then
  echo "ERROR: curl too old; need >= 7.36 for --next." >&2
  exit 1
fi

# Acquire a process-wide lock so two instances can't fight over ifb0/tc.
# Re-execs once under flock with SQM_LOCKED=1 so the inner run skips this.
if [ -z "${SQM_LOCKED:-}" ]; then
  exec env SQM_LOCKED=1 flock -n /tmp/autocake.lock "${0}" "${@}"
fi

# --- autodetected from system state ---
IFACE="$(ip -o route show default 2> /dev/null | awk '{print $5; exit}')"
[ -n "${IFACE}" ] || {
  echo "no default route"
  exit 1
}

# --- algorithmic constants (not link-specific tuning) ---
# Download backends, probed in order. Cloudflare uses a byte-precise URL
# template; mirror entries declare a fixed-size file used with HTTP Range.
# probe_download_backends populates WORKING_DOWNLOAD_BACKENDS with every
# entry that responds at run start; throughput streams are distributed
# round-robin across that pool, so a single mirror that 429s under real
# load (Cloudflare's pattern) cannot zero out the measurement and a slow
# mirror cannot anchor it below the link's true capacity. Format:
# "URL [SIZE_BYTES]" — size omitted means byte-precise template.
DOWNLOAD_BACKENDS=(
  "https://speed.cloudflare.com/__down?bytes=%BYTES%"
  "https://proof.ovh.net/files/1Gb.dat 1073741824"
  "https://speed.hetzner.de/1GB.bin 1073741824"
  "https://speedtest.tele2.net/1GB.zip 1073741824"
)
# Populated by probe_download_backends. Each entry "url|max_bytes" where
# max_bytes=0 marks a byte-precise template URL, and >0 marks a fixed-size
# mirror to be loaded with HTTP Range up to that ceiling.
WORKING_DOWNLOAD_BACKENDS=()
SPEEDTEST_UP_URL="https://speed.cloudflare.com/__up"
# Latency probe backends, tried in order. Connectivity-check endpoints
# (designed for frequent polling) come first so we don't trip Cloudflare's
# small-endpoint rate limit during heavy runs. Cloudflare stays as fallback
# in case the primaries are blocked in a region.
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
CAKE_OPTS="besteffort"
CAKE_INGRESS_OPTS="besteffort wash"
IFB_DEV="ifb0"
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

# Probe every entry in DOWNLOAD_BACKENDS; populate WORKING_DOWNLOAD_BACKENDS
# with each that responds 200 (template URL) or 206 (Range-supporting
# mirror). Returns 0 if at least one backend works. The small probe is
# necessary but not sufficient — a backend can pass and still 429 under
# real 3-stream load (Cloudflare's pattern), but stream distribution makes
# that survivable: the failing backend's stream contributes 0 while
# siblings still saturate the link.
probe_download_backends() {
  WORKING_DOWNLOAD_BACKENDS=()
  local entry url size probe_url code
  for entry in "${DOWNLOAD_BACKENDS[@]}"; do
    url="${entry%% *}"
    size="${entry#* }"
    [ "${size}" = "${entry}" ] && size=0
    if [[ "${url}" == *%BYTES%* ]]; then
      probe_url="${url//%BYTES%/100000}"
      code=$(curl -s -o /dev/null --max-time 8 -w '%{http_code}' "${probe_url}" 2> /dev/null || true)
      code="${code:-000}"
      echo "  probe: ${url%%/__*}/__down?bytes=100000 → ${code}" >&2
      if [ "${code}" = "200" ]; then
        WORKING_DOWNLOAD_BACKENDS+=("${url}|0")
      fi
    else
      code=$(curl -s -o /dev/null --max-time 8 -r 0-99999 -w '%{http_code}' "${url}" 2> /dev/null || true)
      code="${code:-000}"
      echo "  probe: ${url} (Range 0-99999) → ${code}" >&2
      if [ "${code}" = "206" ] || [ "${code}" = "200" ]; then
        WORKING_DOWNLOAD_BACKENDS+=("${url}|${size}")
      fi
    fi
  done
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
# selected by stream index $3. Writes "speed http_code" to $1.
download_curl_bg() {
  local out="$1" bytes="$2" idx="$3"
  pick_download_backend "${idx}"
  if [ "${_pick_max}" = "0" ]; then
    curl -s -o /dev/null --max-time "${CURL_TIMEOUT}" \
      -w '%{speed_download} %{http_code}\n' \
      "${_pick_url//%BYTES%/${bytes}}" > "${out}" &
  else
    [ "${bytes}" -gt "${_pick_max}" ] && bytes="${_pick_max}"
    curl -s -o /dev/null --max-time "${CURL_TIMEOUT}" \
      -r "0-$((bytes - 1))" \
      -w '%{speed_download} %{http_code}\n' \
      "${_pick_url}" > "${out}" &
  fi
}

# Background-fire one load-only download stream (no -w needed; pure load)
# against the round-robin backend selected by stream index $2.
download_load_bg() {
  local bytes="$1" idx="$2"
  pick_download_backend "${idx}"
  if [ "${_pick_max}" = "0" ]; then
    curl -s -o /dev/null --max-time "${LOAD_TIMEOUT}" \
      "${_pick_url//%BYTES%/${bytes}}" > /dev/null &
  else
    [ "${bytes}" -gt "${_pick_max}" ] && bytes="${_pick_max}"
    curl -s -o /dev/null --max-time "${LOAD_TIMEOUT}" \
      -r "0-$((bytes - 1))" \
      "${_pick_url}" > /dev/null &
  fi
}

sqm_off() {
  tc qdisc del dev "${IFACE}" ingress 2> /dev/null || true
  tc qdisc del dev "${IFACE}" root 2> /dev/null || true
  tc qdisc del dev "${IFB_DEV}" root 2> /dev/null || true
  ip link set dev "${IFB_DEV}" down 2> /dev/null || true
  ip link del "${IFB_DEV}" 2> /dev/null || true
}

sqm_apply() {
  local up_cap="${1}" down_cap="${2}"
  modprobe ifb 2> /dev/null || true
  ip link add "${IFB_DEV}" type ifb 2> /dev/null || true
  ip link set dev "${IFB_DEV}" up
  # shellcheck disable=SC2086
  tc qdisc replace dev "${IFACE}" root cake bandwidth "${up_cap}Mbit" ${CAKE_OPTS}
  tc qdisc replace dev "${IFACE}" handle ffff: ingress
  tc filter replace dev "${IFACE}" parent ffff: protocol all matchall \
    action mirred egress redirect dev "${IFB_DEV}"
  # shellcheck disable=SC2086
  tc qdisc replace dev "${IFB_DEV}" root cake bandwidth "${down_cap}Mbit" ${CAKE_INGRESS_OPTS}
}

WORKDIR=$(mktemp -d)
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
trap 'rm -rf "${WORKDIR}"' EXIT
trap on_interrupt INT TERM

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
  local args=(-s -o /dev/null --max-time "${LATENCY_TIMEOUT}"
    -w '%{time_total}\n' "${LATENCY_URL}")
  local i
  for i in $(seq 2 "${count}"); do
    args+=(--next -s -o /dev/null --max-time "${LATENCY_TIMEOUT}" -w '%{time_total}\n' "${LATENCY_URL}")
  done
  curl "${args[@]}" 2> /dev/null |
    tail -n +2 |
    sort -n |
    awk '
        { v[NR] = $1 }
        END {
          if (NR == 0) { print "0 0"; exit }
          p25 = int((NR * 0.25) + 0.5); if (p25 < 1) p25 = 1
          p75 = int((NR * 0.75) + 0.5); if (p75 < 1) p75 = 1; if (p75 > NR) p75 = NR
          p95 = int((NR * 0.95) + 0.5); if (p95 < 1) p95 = 1; if (p95 > NR) p95 = NR
          printf "%.0f %.0f\n", v[p75] * 1000, (v[p95] - v[p25]) * 1000
        }
      '
}

# Robust idle baseline: take IDLE_BURSTS bursts of IDLE_BURST_SAMPLES, echo
# the median burst's "P75 JITTER". Median (not min) so neither a single
# clean burst over-tightens the threshold nor a single noisy burst loosens
# it; the baseline reflects typical link conditions, which is what loaded
# probes need to be measured against to install a stable cap.
idle_baseline() {
  local i p75 jit pairs=""
  for i in $(seq 1 "${IDLE_BURSTS}"); do
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
  printf '%s' "${pairs}" | sort -n | awk '
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
  for i in $(seq 1 "${streams}"); do
    if [ "${dir}" = down ]; then
      download_curl_bg "${WORKDIR}/s${i}" "${bytes}" "$((i - 1))"
    else
      (head -c "${bytes}" /dev/zero |
        curl -s -o /dev/null --max-time "${CURL_TIMEOUT}" -X POST --data-binary @- \
          -w '%{speed_upload} %{http_code}\n' \
          "${SPEEDTEST_UP_URL}") > "${WORKDIR}/s${i}" &
    fi
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "${pid}" 2> /dev/null || true; done

  local total_bps=0 bps http codes=""
  for i in $(seq 1 "${streams}"); do
    read -r bps http < "${WORKDIR}/s${i}" 2> /dev/null || {
      bps=0
      http=0
    }
    codes="${codes}${codes:+,}${http:-curl-fail}"
    # 200 = full body (Cloudflare template), 206 = Partial Content (Range mirror)
    if [ "${http:-0}" = 200 ] || [ "${http:-0}" = 206 ]; then
      total_bps=$(awk -v t="${total_bps}" -v b="${bps:-0}" 'BEGIN{print t+b}')
    fi
    rm -f "${WORKDIR}/s${i}"
  done
  # Surface per-stream HTTP codes when no stream succeeded so the caller's
  # error message points at why (rate limit / CDN error / curl failure).
  [ "${total_bps}" = 0 ] && echo "[${dir}: HTTP codes ${codes}]" >&2
  awk -v b="${total_bps}" 'BEGIN{printf "%d", b*8/1e6 + 0.5}'
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
# return "P75_ms JITTER_ms" under load. Multi-stream load is needed because
# a single HTTP stream often falls short of cap on fast links — the queue
# never fills and the probe falsely reports clean latency.
#
# Liveness check before sampling: on very fast caps, per-stream bytes can
# finish before the probe completes. If at least one stream in either
# direction has already exited, the queue isn't full and the measurement
# would falsely report idle latency. Return "0 0" so the caller fails the
# cap and tries a lower one instead.
loaded_latency_bidir() {
  local down_cap="${1}" up_cap="${2}"
  local down_bytes up_bytes
  down_bytes=$(load_bytes_per_stream "${down_cap}")
  up_bytes=$(load_bytes_per_stream "${up_cap}")

  local down_pids=() up_pids=()
  local i
  for i in $(seq 1 "${STREAMS}"); do
    download_load_bg "${down_bytes}" "$((i - 1))"
    down_pids+=("$!")
    (head -c "${up_bytes}" /dev/zero |
      curl -s -o /dev/null --max-time "${LOAD_TIMEOUT}" -X POST --data-binary @- \
        "${SPEEDTEST_UP_URL}") > /dev/null &
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
  if [ "${alive_down}" -eq 0 ] || [ "${alive_up}" -eq 0 ]; then
    for pid in "${down_pids[@]}" "${up_pids[@]}"; do wait "${pid}" 2> /dev/null || true; done
    echo "0 0"
    return
  fi

  local lat jit
  read -r lat jit < <(http_latency_stats "${LOADED_SAMPLES}")
  for pid in "${down_pids[@]}" "${up_pids[@]}"; do wait "${pid}" 2> /dev/null || true; done
  echo "${lat:-0} ${jit:-0}"
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
  local lat_bad=0 jit_bad=0
  [ "${lat}" -gt "${THRESHOLD_MS}" ] && lat_bad=1
  [ "${jit}" -gt "${JITTER_THRESHOLD_MS}" ] && jit_bad=1
  if [ "${lat_bad}" -eq 0 ] && [ "${jit_bad}" -eq 0 ]; then
    echo "PASS"
  elif [ "${lat_bad}" -eq 1 ] && [ "${jit_bad}" -eq 1 ]; then
    echo "FAIL (latency+jitter)"
  elif [ "${lat_bad}" -eq 1 ]; then
    echo "FAIL (latency)"
  else
    echo "FAIL (jitter)"
  fi
}

# try_pct <pct>: apply cake at pct of measured bandwidth, verify under
# bidirectional load. Sets LAST_DOWN/LAST_UP on a real test. Returns:
#   0 — pass (latency and jitter within thresholds)
#   1 — quality fail (latency or jitter over threshold)
#   2 — floor skip (down cap below STREAMING_GREAT_FLOOR with floor enabled)
# The distinction lets the streaming-floor retry skip caps that already
# failed on quality rather than re-probing them when the floor drops.
try_pct() {
  local pct="${1}"
  local down_cap=$((DL * pct / 100))
  local up_cap=$((UL * pct / 100))
  [ "${down_cap}" -ge 1 ] && [ "${up_cap}" -ge 1 ] || return 1

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

  local tag
  tag=$(classify_tag "${lat}" "${jit}")
  echo "  ${pct}% → ${down_cap}/${up_cap} Mbit → P75: ${lat}ms (≤${THRESHOLD_MS}) jitter: ${jit}ms (≤${JITTER_THRESHOLD_DISPLAY}) [${tag}]"
  [ "${tag}" = "PASS" ] && return 0
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
    2)
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

# ---------- Main flow ----------

sqm_off
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
  echo "ERROR: idle latency probe failed — Cloudflare unreachable?" >&2
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

# Adaptive threshold: mult × jitter, clamped.
# Floor: cake can deliver ~5-8 ms loaded delta on a clean link.
# Ceiling: anything beyond ~25 ms is bufferbloat regardless of jitter.
THRESHOLD_EXTRA_MS=$((IDLE_JITTER * JITTER_THRESHOLD_MULT))
[ "${THRESHOLD_EXTRA_MS}" -lt "${THRESHOLD_EXTRA_MIN_MS}" ] && THRESHOLD_EXTRA_MS="${THRESHOLD_EXTRA_MIN_MS}"
[ "${THRESHOLD_EXTRA_MS}" -gt "${THRESHOLD_EXTRA_MAX_MS}" ] && THRESHOLD_EXTRA_MS="${THRESHOLD_EXTRA_MAX_MS}"
THRESHOLD_MS=$((IDLE + THRESHOLD_EXTRA_MS))

# Loaded-jitter gate. If the link's idle jitter is already above Cloudflare's
# Great ceiling, no shaping can deliver Great anyway — disable the gate and
# leave selection to the latency threshold. Otherwise demand loaded jitter
# stay within the Great ceiling.
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
echo "  unshaped: P75=${UNSHAPED_LAT}ms (≤${THRESHOLD_MS}) jitter=${UNSHAPED_JIT}ms (≤${JITTER_THRESHOLD_DISPLAY}) [$(classify_tag "${UNSHAPED_LAT}" "${UNSHAPED_JIT}")]"
if [ "${UNSHAPED_LAT}" -gt 0 ] && [ "${UNSHAPED_LAT}" -le "${THRESHOLD_MS}" ] && [ "${UNSHAPED_JIT}" -le "${JITTER_THRESHOLD_MS}" ]; then
  echo "SQM not needed — link already meets thresholds unshaped. Leaving off."
  exit 0
fi

# Coarse pass: walk the step ladder until one passes.
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

# Best-effort fallback: no cap met strict thresholds, but if some tested
# cap reduced loaded P75 by more than a third vs unshaped, applying it is
# strictly better than leaving the link wide open at unshaped bufferbloat.
# RF-limited / WiFi-extender links typically land here — they can't reach
# Cloudflare's "Great" tier no matter what, but the user still benefits
# from a controlled queue.
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

# Refine: binary-search upward between BEST_PCT (passing) and FAIL_PCT (failing,
# or the ceiling if nothing failed above).
if [ "${FAIL_PCT}" -gt "${BEST_PCT}" ]; then
  echo "Refining between ${BEST_PCT}% and ${FAIL_PCT}% (up to ${REFINE_ITERS} iterations)..."
  LO="${BEST_PCT}"
  HI="${FAIL_PCT}"
  for _ in $(seq 1 "${REFINE_ITERS}"); do
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

# Stability re-verification: re-test the chosen cap. If the win doesn't
# reproduce, step down one rung and re-check rather than installing a
# transient pass that won't hold during real use.
echo "Re-verifying stability at ${BEST_PCT}%..."
sqm_apply "${BEST_UP}" "${BEST_DOWN}"
read -r RECHECK_LAT RECHECK_JIT < <(loaded_latency_bidir "${BEST_DOWN}" "${BEST_UP}")
echo "  recheck: P75=${RECHECK_LAT}ms (≤${THRESHOLD_MS}) jitter=${RECHECK_JIT}ms (≤${JITTER_THRESHOLD_DISPLAY}) [$(classify_tag "${RECHECK_LAT}" "${RECHECK_JIT}")]"
USED_STEPDOWN=0
if [ "${BEST_EFFORT}" -eq 1 ]; then
  echo "  best-effort cap; strict recheck skipped (link can't meet 'Great' thresholds anyway)"
elif [ "${RECHECK_LAT}" -gt 0 ] && [ "${RECHECK_LAT}" -le "${THRESHOLD_MS}" ] && [ "${RECHECK_JIT}" -le "${JITTER_THRESHOLD_MS}" ]; then
  echo "  stable"
else
  FALLBACK_PCT=$((BEST_PCT - 5))
  if [ "${FALLBACK_PCT}" -ge 30 ]; then
    echo "  not stable — stepping down to ${FALLBACK_PCT}%"
    if try_pct "${FALLBACK_PCT}"; then
      # Double-check the fallback before committing — the same transient
      # variance that broke the original recheck could have produced a
      # false-pass on the step-down.
      sqm_apply "${LAST_UP}" "${LAST_DOWN}"
      read -r FB_LAT FB_JIT < <(loaded_latency_bidir "${LAST_DOWN}" "${LAST_UP}")
      echo "  fallback recheck: P75=${FB_LAT}ms (≤${THRESHOLD_MS}) jitter=${FB_JIT}ms (≤${JITTER_THRESHOLD_DISPLAY}) [$(classify_tag "${FB_LAT}" "${FB_JIT}")]"
      if [ "${FB_LAT}" -gt 0 ] && [ "${FB_LAT}" -le "${THRESHOLD_MS}" ] && [ "${FB_JIT}" -le "${JITTER_THRESHOLD_MS}" ]; then
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
      fi
    fi
  else
    echo "  not stable but already at floor — keeping ${BEST_PCT}%"
  fi
fi

# Confidence assessment: a one-line label backed by simple signals so the
# user knows whether to trust the picked cap or re-run for a cleaner read.
# No additional probing — purely a synthesis of evidence already collected.
#   + idle jitter (noisy idle = lower confidence)
#   + backend pool size (more diverse = better link-capacity reading)
#   + recheck delta vs search probe (large drift = high variance)
#   + which path picked the cap (clean PASS / step-down / best-effort)
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
if [ "${BEST_LAT:-0}" -gt 0 ] && [ "${RECHECK_LAT:-0}" -gt 0 ]; then
  RECHECK_DELTA=$((RECHECK_LAT - BEST_LAT))
  [ "${RECHECK_DELTA}" -lt 0 ] && RECHECK_DELTA=$((-RECHECK_DELTA))
  if [ "${RECHECK_DELTA}" -le 3 ]; then
    CONF_SCORE=$((CONF_SCORE + 1))
  elif [ "${RECHECK_DELTA}" -ge 8 ]; then
    CONF_SCORE=$((CONF_SCORE - 1))
    CONF_NOTES+=("recheck drifted ${RECHECK_DELTA}ms vs search probe")
  fi
fi
if [ "${BEST_EFFORT:-0}" -eq 1 ]; then
  CONF_SCORE=$((CONF_SCORE - 2))
  CONF_NOTES+=("best-effort cap (link can't reach Cloudflare 'Great')")
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
echo "SQM ON at ${BEST_PCT}% — DOWN=${BEST_DOWN}Mbit UP=${BEST_UP}Mbit  [confidence: ${CONFIDENCE}]"
if [ "${#CONF_NOTES[@]}" -gt 0 ]; then
  for _note in "${CONF_NOTES[@]}"; do
    echo "  note: ${_note}"
  done
fi
