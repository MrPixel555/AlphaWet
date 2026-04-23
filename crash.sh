#!/system/bin/sh

PKG="ir.alphacraft.alphawet"
WAIT_SECS=30
OUT="/sdcard/alpha_watch_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUT"

echo "[*] output dir: $OUT"

ts() {
  date "+%Y-%m-%d %H:%M:%S"
}

mark() {
  echo "[$(ts)] $*" | tee -a "$OUT/trace.txt"
}

get_pid() {
  pidof "$PKG" 2>/dev/null | awk '{print $1}'
}

dump_snapshot() {
  SNAP="$OUT/snapshot_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$SNAP"

  mark "dumping snapshot into $SNAP"

  dumpsys activity exit-info "$PKG" > "$SNAP/exit_info.txt" 2>/dev/null
  dumpsys activity processes > "$SNAP/processes.txt" 2>/dev/null
  dumpsys activity top > "$SNAP/activity_top.txt" 2>/dev/null
  dumpsys activity activities > "$SNAP/activities.txt" 2>/dev/null
  dumpsys meminfo "$PKG" > "$SNAP/meminfo_pkg.txt" 2>/dev/null
  dumpsys meminfo > "$SNAP/meminfo_full.txt" 2>/dev/null
  dumpsys package "$PKG" > "$SNAP/package.txt" 2>/dev/null
  ps -A -o PID,PPID,USER,NAME,ARGS > "$SNAP/ps.txt" 2>/dev/null
  top -b -n 1 > "$SNAP/top.txt" 2>/dev/null

  cat /data/anr/traces.txt > "$SNAP/anr_traces.txt" 2>/dev/null

  mkdir -p "$SNAP/tombstones"
  cp /data/tombstones/* "$SNAP/tombstones/" 2>/dev/null
}

mark "clearing logs..."
logcat -b main -b system -b crash -b events -c 2>/dev/null

mark "saving pre-launch package/process state..."
dump_snapshot

mark "launching app..."
monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

sleep 2

PID="$(get_pid)"
mark "initial pid: ${PID:-<none>}"

if [ -z "$PID" ]; then
  mark "app did not start or pid not found"
fi

mark "starting live log capture..."
logcat -v threadtime -b main -b system -b crash -b events > "$OUT/logcat_live.txt" 2>&1 &
LOGCAT_PID=$!
echo "$LOGCAT_PID" > "$OUT/logcat_pid.txt"

START_TS=$(date +%s)
LAST_PID="$PID"
DEATH_DETECTED=0

while true; do
  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - START_TS))

  CUR_PID="$(get_pid)"

  if [ "$CUR_PID" != "$LAST_PID" ]; then
    mark "pid changed: old=${LAST_PID:-<none>} new=${CUR_PID:-<none>}"
    LAST_PID="$CUR_PID"
  fi

  if [ -n "$PID" ] && [ -z "$CUR_PID" ]; then
    mark "process disappeared -> possible external kill / crash / ANR"
    DEATH_DETECTED=1
    dump_snapshot
    break
  fi

  if [ "$ELAPSED" -ge "$WAIT_SECS" ]; then
    mark "timeout reached ($WAIT_SECS sec)"
    dump_snapshot
    break
  fi

  sleep 1
done

mark "stopping logcat capture..."
kill "$LOGCAT_PID" 2>/dev/null
sleep 1

mark "saving final full dumps..."
logcat -d -v threadtime -b main -b system -b crash -b events > "$OUT/logcat_full.txt" 2>/dev/null

grep -i -n -E \
"Force stopping|Killing [0-9]+:$PKG|Process [0-9]+ exited due to signal|am_kill|lowmemorykiller|lmkd|LMKD|reason=|ApplicationExitInfo|exit reason|FATAL EXCEPTION|AndroidRuntime|ANR in|Fatal signal|Abort message|backtrace|SIGSEGV|SIGABRT|OutOfMemoryError|UnsatisfiedLinkError|SecurityException|NullPointerException|IllegalStateException|NoClassDefFoundError|ClassNotFoundException|dlopen failed" \
"$OUT/logcat_full.txt" > "$OUT/focus_kill_and_crash.txt" 2>/dev/null

dumpsys activity exit-info "$PKG" > "$OUT/exit_info_final.txt" 2>/dev/null
dumpsys activity processes > "$OUT/processes_final.txt" 2>/dev/null
dumpsys meminfo "$PKG" > "$OUT/meminfo_pkg_final.txt" 2>/dev/null
dumpsys meminfo > "$OUT/meminfo_full_final.txt" 2>/dev/null
dumpsys package "$PKG" > "$OUT/package_final.txt" 2>/dev/null
ps -A -o PID,PPID,USER,NAME,ARGS > "$OUT/ps_final.txt" 2>/dev/null

echo
echo "[*] done"
echo
echo "Important files:"
echo "  $OUT/trace.txt"
echo "  $OUT/logcat_live.txt"
echo "  $OUT/logcat_full.txt"
echo "  $OUT/focus_kill_and_crash.txt"
echo "  $OUT/exit_info_final.txt"
echo "  $OUT/processes_final.txt"
echo "  $OUT/meminfo_pkg_final.txt"
echo "  $OUT/meminfo_full_final.txt"
echo "  $OUT/snapshot_*/"