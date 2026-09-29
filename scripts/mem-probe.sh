#!/usr/bin/env bash
# mem-probe.sh — measure a Tauri/WebView app's memory correctly
#
# Why this exists
# ---------------
# Two traps make naive `footprint <pid>` numbers wrong for Tauri apps:
#
#   1. WKWebView is multi-process. The renderer (where the whole React
#      app and xterm.js live) runs in a separate com.apple.WebKit.WebContent
#      process whose ppid is reparented to launchd, so parent/child
#      relationships do not identify it. Measuring only the main binary
#      misses the renderer entirely.
#
#   2. `footprint` is unusable for those XPC processes. It counts the
#      virtual address space WebKit reserves for JIT and GC heaps. Measured
#      on this machine: a WebKit.Networking process holding 6.3 MB resident
#      is reported as 8769 MB — off by three orders of magnitude. Use RSS.
#
# And one trap for attribution:
#
#   3. WebKit processes are reaped lazily. After the host app quits, other
#      apps' WebKit processes linger for seconds. "This process vanished
#      when I quit the app" therefore does NOT prove ownership. Use a
#      before/after diff instead.
#
# Usage
# -----
#   bash scripts/mem-probe.sh snapshot <label>
#   bash scripts/mem-probe.sh diff <labelA> <labelB>
#   bash scripts/mem-probe.sh totals <label>   # RSS breakdown, no diff
#
# Example
# -------
#   bash scripts/mem-probe.sh snapshot before
#   open -a /Applications/r-shell.app          # or launch however you like
#   sleep 20
#   bash scripts/mem-probe.sh snapshot after
#   bash scripts/mem-probe.sh diff before after
#
# Caveat: this attributes by what appeared, not by what is truly used.
# If another WebKit app launches in the same window it will be counted too.
# For a clean read, take the baseline with nothing else starting.

set -u
SNAP_DIR="${TMPDIR:-/tmp}/r-shell-mem-probe"
mkdir -p "$SNAP_DIR"

# Only processes that could plausibly belong to a Tauri/WebView app.
# The app binary is matched by path *ending* in "r-shell" so that unrelated
# executables whose names merely contain it (e.g. r-shell-gpui-poc) are not
# swept in. Adjust that pattern if you point this at a different app.
APP_RE='\/r-shell$'

filter() {
  awk -v app="$APP_RE" '
    $3 ~ app || $3 ~ /WebKit/ {
      printf "%d\t%.1f\n", $1, $2/1024
    }' | sort -n -k1,1
}

snapshot() {
  local label=$1 out="$SNAP_DIR/$1.tsv"
  ps -axo pid=,rss=,comm= | filter > "$out"
  local n
  n=$(wc -l < "$out" | tr -d ' ')
  echo "snapshot [$label] → $out ($n processes)"
}

# Report RSS totals per executable family, so the WebView processes are
# visible as their own line rather than hidden inside the total.
totals() {
  local label=$1
  echo "  RSS by family [$label]:"
  ps -axo pid=,rss=,comm= | awk -v app_re="$APP_RE" '
    $3 ~ app_re { r += $2; app++ }
    $3 ~ /WebContent/ { w += $2; wc++ }
    $3 ~ /WebKit.GPU/ { g += $2; gc++ }
    $3 ~ /Networking/ { n += $2; nc++ }
    END {
      printf "    app binary      %8.1f MB  (%d proc)\n", r/1024, app
      printf "    WebKit render   %8.1f MB  (%d proc)\n", w/1024, wc
      printf "    WebKit GPU      %8.1f MB  (%d proc)\n", g/1024, gc
      printf "    WebKit network  %8.1f MB  (%d proc)\n", n/1024, nc
      printf "    %-15s %8.1f MB\n", "TOTAL", (r+w+g+n)/1024
    }'
}

diff_snap() {
  local a=$1 b=$2
  local fa="$SNAP_DIR/$a.tsv" fb="$SNAP_DIR/$b.tsv"
  [ -f "$fa" ] && [ -f "$fb" ] || { echo "missing snapshot"; exit 1; }

  echo "── appeared between [$a] and [$b] ──"
  comm -13 <(cut -f1 "$fa") <(cut -f1 "$fb") | while read -r pid; do
    grep -P "^${pid}\t" "$fb" | awk -F'\t' \
      '{printf "  pid=%-7s +%8.1f MB\n", $1, $2}'
    r=$(grep -P "^${pid}\t" "$fa" | cut -f2)
    [ -n "$r" ] && echo "  pid=$pid  was $r MB before, now: $r MB → see diff below"
  done

  echo
  echo "── disappeared ──"
  comm -23 <(cut -f1 "$fa") <(cut -f1 "$fb") | while read -r pid; do
    grep -P "^${pid}\t" "$fa" | awk -F'\t' \
      '{printf "  pid=%-7s -%8.1f MB\n", $1, $2}'
  done

  echo
  echo "── RSS change on surviving processes (>5 MB) ──"
  join -t $'\t' "$fa" "$fb" | awk -F'\t' '
    $3 - $2 > 5 { printf "  pid=%-7s %+8.1f MB\n", $1, $3-$2; s += $3-$2 }
    END { if (s) printf "  %-12s %+8.1f MB\n", "subtotal", s }'

  echo
  totals "$b"
}

case "${1:-}" in
  snapshot) [ -n "${2:-}" ] && snapshot "$2" || echo "need a label" ;;
  diff)     [ -n "${2:-}" ] && [ -n "${3:-}" ] && diff_snap "$2" "$3" || echo "need two labels" ;;
  totals)   [ -n "${2:-}" ] && totals "$2" || echo "need a label" ;;
  *) echo "usage: mem-probe.sh snapshot <label> | diff <A> <B> | totals <label>"; exit 1 ;;
esac
