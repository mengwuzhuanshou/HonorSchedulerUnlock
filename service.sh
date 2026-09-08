#!/system/bin/sh
# Honor Charge Unlock daemon - KSU/Magisk compatible
# Removes the OS screen-on charging power cap by resetting direct-charge
# iin_thermal limits (the charge FW recomputes them to its max when set to 0).
MODDIR=${0%/*}
CONF=/data/adb/honor_charge_unlock.conf
LOG=/data/adb/honor_charge_unlock.log
PIDF=/data/adb/honor_charge_unlock.pid

BATT_UE=/sys/class/power_supply/battery/uevent
IFACE=/sys/class/hw_power/interface
DC=/sys/class/hw_power/charger

# ---------- config ----------
screen_on_unlock=1
unlock_when_screen_off=1
poll_interval=0.3
temp_guard=0
protocol_poke=1
include_lvc=1
verbose=0
# explicit iin_thermal value written each cycle; the kernel clamps it to the
# per-path temp_para row on write (12000/14500 below 44C), so a large value
# is safe and takes effect instantly (no recompute delay like write-0)
max_iin=20000

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
# Honor Charge Unlock config (values take effect after daemon restart or reboot)
# 1 = on, 0 = off
screen_on_unlock=1
# also force limits while screen is off (default on: full-time unlock)
unlock_when_screen_off=1
# poll interval in seconds (fractional ok). the OS re-caps limits every ~4.5s;
# 0.3s keeps the unlocked value up ~90% of the time
poll_interval=0.3
# pause unlocking when battery temp >= this (degC*10). 0 disables the guard.
# NOTE: the kernel clamps iin_thermal to its own temp_para table anyway
# (12000/14500 below 44C, 6000 at 44-45C, 1700 at 45-50C, 0 above 50C),
# so this guard is only extra margin on top of that in-kernel ladder.
temp_guard=0
# try poking protocol enable nodes (pd/hvc/hsc) on boot and charger plug
protocol_poke=1
# include the LVC path (direct_charger) besides SCP/HSC(UFCS)
include_lvc=1
# launch boost v2: pin min=max on all clusters via perfserv_freq QoS votes
# for the launch window (ends at ActivityManager "Displayed" first frame or
# launch_boost_ms timeout, whichever first). Renewal-dominant: the proc write
# replaces the per-cluster PM-QoS min/max vote PAIR atomically and the last
# writer owns it, so a ~10-30Hz re-pin wins the race against perfserv's own
# launch caps (p4<=3.0G / p7<=3.5G) -> whole window runs at cluster max.
launch_boost=1
launch_boost_ms=2000
# scroll clamp: policy4 (big cluster) max in kHz while the finger is down,
# same QoS vote channel (100% occupancy measured at >=10Hz renewal).
# Touch source = wakeup_sources event2 counter (real touches only).
# Taobao 120Hz ladder (2026-09-07): 0.8G == 0.9G frame pacing (legacy janky
# 13.75% vs 14.50%, p99 21 vs 26ms), 0.7G+ degrades monotonically -> 0.8G.
scroll_cap=800000
# keep iAware app-preload features off (cloud may re-push values)
disable_preload=1
# --- FCM keep-alive unlock (v1.9; mechanism notes in docs/FCM通路逆向笔记.md) ---
# Honor China ROM probes "google connectivity" by HTTP-GETting google.com; on
# failure it silently drops GMS partial wakelocks (MCS push dies in doze),
# PowerGenie firewall-blocks the GMS uid, and after a 7-day grace iAware strips
# GMS apps of their background privileges. All three layers key off that probe.
fcm_unlock=1
# probe re-assert interval (seconds); also re-runs the keepalive/grace/gms keeps
fcm_interval=1800
# URLs fed to the probe (must answer HTTP 200, be reachable in CN; probe stops
# at the first success). Oversea-SIM devices short-circuit to OK anyway.
fcm_probe_urls=http://www.baidu.com,http://www.qq.com
# notifyGoogleKeepAlive(com.google.android.gms, true): freeze-exempt + unfreeze GMS
fcm_keepalive=1
# keep persist.sys.iaware_google_conn="0,1" so every boot starts a fresh 7-day grace
fcm_grace_keeper=1
# keep Settings.Secure google_service_status=1 (google components enabled)
fcm_gms_on=1
verbose=0
EOF
fi
# shellcheck disable=SC1090
. "$CONF" 2>/dev/null

# merge keys added by upgrades into existing confs (template above is only
# written on first install; never clobber values already present)
conf_add() {
  grep -q "^$1=" "$CONF" 2>/dev/null || echo "$1=$2" >> "$CONF"
}
conf_add screen_on_unlock 1
conf_add unlock_when_screen_off 1
conf_add poll_interval 0.3
conf_add temp_guard 0
conf_add protocol_poke 1
conf_add include_lvc 1
conf_add max_iin 20000
conf_add launch_boost 1
conf_add launch_boost_ms 2000
conf_add scroll_cap 800000
conf_add disable_preload 1
conf_add fcm_unlock 1
conf_add fcm_interval 1800
conf_add fcm_probe_urls "http://www.baidu.com,http://www.qq.com"
conf_add fcm_keepalive 1
conf_add fcm_grace_keeper 1
conf_add fcm_gms_on 1
conf_add verbose 0
# re-source: conf_add only appends to the file, but an upgraded conf means the
# first source above ran without the new keys -> without this, fcm_* stay
# empty until the next reboot (same class of bug as the v1.8.0 template lesson)
. "$CONF" 2>/dev/null

log() {
  [ "$verbose" = "1" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null)
  if [ "${sz:-0}" -gt 32768 ]; then : > "$LOG"; fi
  echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"
}

screen_awake() {
  # Awake/Dozing/Asleep; Dozing can still be "display off" -> only Awake counts
  dumpsys power 2>/dev/null | grep -qm1 'mWakefulness=Awake'
}

do_unlock() {
  echo "$max_iin" > "$DC/direct_charger_sc/iin_thermal" 2>/dev/null
  echo "$max_iin" > "$DC/direct_charger_hsc/iin_thermal" 2>/dev/null
  [ "$include_lvc" = "1" ] && echo "$max_iin" > "$DC/direct_charger/iin_thermal" 2>/dev/null
  echo "$max_iin" > "$IFACE/iin_thermal" 2>/dev/null
  echo "$max_iin" > "$IFACE/ichg_thermal" 2>/dev/null
}

poke_protocols() {
  # best-effort; on many builds enable_charger is a read-only view kept by the
  # charge FW (values then follow the attached adapter). Harmless if ignored.
  echo "pd 1" > "$IFACE/enable_charger" 2>/dev/null
  echo "hvc 1" > "$IFACE/enable_charger" 2>/dev/null
  echo "hsc 1" > "$IFACE/enable_charger" 2>/dev/null
  echo "sc 1" > "$IFACE/enable_charger" 2>/dev/null
  echo 1 > "$IFACE/charge_turbo_enable" 2>/dev/null
}

dump_arbitration() {
  # protocol arbitration evidence after a plug event (fills in with real adapters)
  {
    echo "=== plug $(date) adapter=$(cat /sys/class/hw_power/adapter/adapter_type 2>/dev/null) support_mode=$(cat /sys/class/hw_power/adapter/support_mode 2>/dev/null)"
    echo "    max_volt=$(cat /sys/class/hw_power/adapter/max_volt 2>/dev/null) max_cur=$(cat /sys/class/hw_power/adapter/max_cur 2>/dev/null) fwver=$(cat /sys/class/hw_power/adapter/fwver 2>/dev/null)"
    dmesg | grep -E "adapter_prot_arbitration|protocol_info|chg_adapter|ufcs|pd_max_watt|pe4" | tail -30
  } >> "$LOG" 2>&1
}

# single instance (validate the pid actually is our daemon, pidfile survives reboot)
if [ -f "$PIDF" ]; then
  old=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$old" ] && [ -d "/proc/$old" ] && grep -q "honor_charge_unlock/service.sh" "/proc/$old/cmdline" 2>/dev/null; then
    exit 0
  fi
  rm -f "$PIDF"
fi
echo $$ > "$PIDF"

# wait for boot
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 10

log "daemon started pid=$$"

# ---------- launch boost (v2.0, perfserv_freq QoS pin) ----------
# Start  : ActivityManager "Start proc <pid>:<pkg> ... for [next-]top-activity"
# End    : ActivityTaskManager "Displayed <pkg>" (first frame) or ms timeout
# Method : write min=max pins to /proc/powerhal_cpu_ctrl/perfserv_freq. That
#          proc write atomically replaces the per-cluster PM-QoS min/max vote
#          PAIR (slot->cluster: 0-3=policy0, 4-6=policy4, 7=policy7) and the
#          last writer owns the pair, so re-pinning at ~10-30Hz wins the race
#          against perfserv's own launch caps (p4<=3.0G / p7<=3.5G): the whole
#          window runs pinned at cluster max (4.21G super core included).
#          (v1.6 raised scaling_min_freq via sysfs instead: cpufreq clamps
#          sysfs-min into the QoS range, so it could never pass 3.5G.)
# Safety : Displayed releases early; epoch prevents stale restores; hard cap
#          launch_boost_ms<=5000; zero-fork fifo pacer for the renewal ticks.
NODE=/proc/powerhal_cpu_ctrl/perfserv_freq
FG_FIF=/data/local/tmp/.hcu_tick
SC_FIF=/data/local/tmp/.hcu_tick2
FG_FLAG=/data/local/tmp/.hcu_lb_active
LB_EPOCH=/data/local/tmp/.hcu_lb_epoch
FG_P0MAX=2700000; FG_P4MAX=3500000; FG_P7MAX=4210000; FG_PMIN=300000
rm -f $FG_FLAG 2>/dev/null   # stale flag would pause scroll clamp until next boost
[ "$launch_boost_ms" -gt 5000 ] 2>/dev/null && launch_boost_ms=5000
lb_boost_on() {
  echo 0 $FG_P0MAX $FG_P0MAX > $NODE 2>/dev/null
  echo 4 $FG_P4MAX $FG_P4MAX > $NODE 2>/dev/null
  echo 7 $FG_P7MAX $FG_P7MAX > $NODE 2>/dev/null
  : > $FG_FLAG 2>/dev/null
}
lb_boost_off() {
  echo 0 $FG_PMIN $FG_P0MAX > $NODE 2>/dev/null
  echo 4 $FG_PMIN $FG_P4MAX > $NODE 2>/dev/null
  echo 7 $FG_PMIN $FG_P7MAX > $NODE 2>/dev/null
  rm -f $FG_FLAG 2>/dev/null
}
fg_fifo() {  # $1 = fifo path; one long-sleep holder, readers use read -t (no fork)
  [ -p "$1" ] || { rm -f "$1"; mkfifo "$1" 2>/dev/null; }
  pgrep -f "sleep 99999999" >/dev/null 2>&1 || sleep 99999999 > "$1" 2>/dev/null &
}
lb_renew() {  # $1=myepoch: re-pin every 100ms until epoch moves or ticks run out
  n=$(( ${launch_boost_ms:-2000} / 100 ))
  while [ $n -gt 0 ]; do
    lb_boost_on
    read -t 0.1 x < "$FG_FIF" 2>/dev/null || :
    [ "$(cat $LB_EPOCH 2>/dev/null)" != "$1" ] && return
    n=$((n-1))
  done
  [ "$(cat $LB_EPOCH 2>/dev/null)" = "$1" ] && lb_boost_off
}
lb_watch() {
  fg_fifo "$FG_FIF"
  echo 0 > "$LB_EPOCH"
  logcat -v brief -s ActivityManager:I ActivityTaskManager:I 2>/dev/null | while read -r line; do
    case "$line" in
      *"Start proc "*for\ top-activity*|*"Start proc "*for\ next-top-activity*)
        n=$(( $(cat "$LB_EPOCH") + 1 )); echo "$n" > "$LB_EPOCH"
        lb_boost_on
        lb_renew "$n" &
        ;;
      Displayed\ *)
        n=$(( $(cat "$LB_EPOCH") + 1 )); echo "$n" > "$LB_EPOCH"
        lb_boost_off
        ;;
    esac
  done
}
if [ "$launch_boost" = "1" ]; then
  lb_watch &
  log "launch_boost watcher started (v2 perfserv_freq QoS pin)"
fi
# ---------- scroll cap (v2, QoS vote channel) ----------
# Touch = wakeup_sources event2 event_count deltas (real finger only; injected
# input is invisible to it). While touched (+hold ticks), re-write the policy4
# vote pair with max=scroll_cap at ~20Hz; perfserv's scroll economy writes lose
# the race (100% occupancy measured). Paused while a launch boost owns the pair
# (flag file), resumed after.
sc_watch() {
  [ -p "$SC_FIF" ] || { rm -f "$SC_FIF"; mkfifo "$SC_FIF" 2>/dev/null; }
  pgrep -f "sleep 99999998" >/dev/null 2>&1 || sleep 99999998 > "$SC_FIF" 2>/dev/null &
  last_ev=X; touch_t=-99; tick=0; mode=IDLE
  while :; do
    tick=$((tick+1))
    read -t 0.1 x < "$SC_FIF" 2>/dev/null || :
    if [ $((tick % 2)) -eq 0 ]; then
      ev=$(grep -m1 -s ^event2 /proc/wakeup_sources 2>/dev/null)
      case $ev in "$last_ev") ;; *) touch_t=$tick; last_ev=$ev ;; esac
    fi
    if [ -f "$FG_FLAG" ]; then mode=BOOST; continue; fi
    if [ $((tick - touch_t)) -lt ${scroll_hold_ticks:-4} ]; then
      echo 4 $FG_PMIN $scroll_cap > $NODE 2>/dev/null
      echo 4 $FG_PMIN $scroll_cap > $NODE 2>/dev/null
      mode=SCROLL
    elif [ "$mode" = SCROLL ]; then
      echo 4 $FG_PMIN $FG_P4MAX > $NODE 2>/dev/null
      mode=IDLE
    fi
  done
}
if [ "$scroll_cap" != "0" ] && [ -n "$scroll_cap" ]; then
  sc_watch &
  log "scroll_cap watcher started (v2 QoS cap=$scroll_cap)"
fi

# ---------- FCM keep-alive unlock (v1.9) ----------
# All calls are uid-1000 binder transactions on the "pgservice" service
# (PGManagerService, IPGManager AIDL):
#   tx12 setPgConfig(6 /*CONFIG_TYPE_GOOGLE_CTRL*/, 0, urls)
#        -> PGGoogleServicePolicy probes those URLs instead of google.com;
#           first HTTP 200 flips the whole ROM into "google connected" state
#           (wakelock filter off, no uid firewall, iAware grace maintained).
#   tx21 notifyGoogleKeepAlive("com.google.android.gms", true)
#        -> setPgShouldNotFreeze + immediate unfreeze of GMS processes.
# Root-only, no persistent processes, no LSP injection (broken on Honor).
FCM_STF=/data/adb/honor_charge_unlock.fcm
fcm_urls=$(printf '%s' "$fcm_probe_urls" | tr -d ' \t\r' | tr ',' ' ')
fcm_avail=1

fcm_assert() {
  [ "$fcm_avail" = "1" ] || return 2
  [ -n "$fcm_urls" ] || { echo "off no-urls" > "$FCM_STF" 2>/dev/null; return 1; }
  n=0
  for u in $fcm_urls; do n=$((n+1)); done
  args="i32 6 i32 0 i32 $n"
  for u in $fcm_urls; do args="$args s16 $u"; done
  out=$(su 1000 -c "service call pgservice 12 $args" 2>&1)
  case "$out" in
    *00000001*) st=ok ;;
    *"Can't find service"*|*"not found"*)
      fcm_avail=0; echo "nosvc" > "$FCM_STF" 2>/dev/null
      log "fcm: pgservice not available, fcm_unlock disabled this boot"
      return 2 ;;
    *) return 1 ;;   # PG not ready yet -> retry shortly
  esac
  if [ "$fcm_keepalive" = "1" ]; then
    su 1000 -c "service call pgservice 21 s16 com.google.android.gms i32 1" >/dev/null 2>&1
  fi
  if [ "$fcm_grace_keeper" = "1" ]; then
    # iAware reads this once per boot: disconn=0(conned-since-epoch), conn=1
    # -> grace period (default 7d, cloud key google_delaytime) always fresh
    [ "$(getprop persist.sys.iaware_google_conn)" != "0,1" ] && \
      setprop persist.sys.iaware_google_conn "0,1" 2>/dev/null
  fi
  if [ "$fcm_gms_on" = "1" ] && pm path com.google.android.gms >/dev/null 2>&1; then
    [ "$(settings get secure google_service_status 2>/dev/null)" != "1" ] && \
      settings put secure google_service_status 1 2>/dev/null
  fi
  echo "$st n=$n" > "$FCM_STF" 2>/dev/null
  log "fcm: probe urls injected ($n) + keepalive/grace/gms asserted"
  # verify the ACTUAL probe verdict (injection success != probe success);
  # async so the charge-reassert loop never stalls
  {
    sleep 8
    lc=$(logcat -d -t 300 -s PGGoogleServicePolicy:D 2>/dev/null | tail -20)
    case "$lc" in
      *"connect google success"*) v="probe:ok" ;;
      *"connect google failed"*) v="probe:fail" ;;
      *) v="" ;;
    esac
    if [ -n "$v" ]; then
      echo "$st n=$n $v" > "$FCM_STF" 2>/dev/null
      log "fcm: probe verdict $v"
    fi
  } &
  return 0
}

fcm_last=0
fcm_boot_boost=5   # dense 60s re-asserts right after daemon start (PowerGenie re-push race)

prev_online=""
cycle=0
applied=0
while :; do
  if [ -f /data/adb/honor_charge_unlock.paused ]; then
    sleep 1; continue
  fi
  # refresh inputs every 10 cycles; writes run every cycle
  if [ $((cycle % 10)) -eq 0 ]; then
    ue=$(cat "$BATT_UE" 2>/dev/null)
    status=${ue#*POWER_SUPPLY_STATUS=}; status=${status%%$'\n'*}
    temp=${ue#*POWER_SUPPLY_TEMP=}; temp=${temp%%$'\n'*}
    online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
    if [ "$protocol_poke" = "1" ] && [ "$online" = "1" ] && [ "$prev_online" != "1" ]; then
      poke_protocols; log "protocol poke on plug"
      { sleep 8; dump_arbitration; } &
    fi
    prev_online=$online
    want=0
    if [ "$online" = "1" ]; then
      if [ "$unlock_when_screen_off" = "1" ]; then want=1
      elif [ "$screen_on_unlock" = "1" ] && screen_awake; then want=1; fi
    fi
    guarded=0
    [ "$temp_guard" != "0" ] && [ "${temp:-0}" -ge "$temp_guard" ] 2>/dev/null && guarded=1
    [ "$guarded" = "1" ] && want=0
  fi
  if [ "$want" = "1" ]; then
    do_unlock
    applied=$((applied + 1))
    [ $((applied % 600)) -eq 1 ] && \
      log "unlock applied (status=$status temp=$temp sc=$(cat "$DC/direct_charger_sc/iin_thermal" 2>/dev/null) hsc=$(cat "$DC/direct_charger_hsc/iin_thermal" 2>/dev/null))"
  fi
  # re-assert preload-disable every ~60 cycles (cloud config may re-push)
  if [ "$disable_preload" = "1" ] && [ $((cycle % 60)) -eq 0 ]; then
    [ "$(getprop persist.sys.iaware.activitypreload.version)" != "0" ] && setprop persist.sys.iaware.activitypreload.version 0
    [ "$(getprop persist.sys.iaware.preloadoptenable)" != "0" ] && setprop persist.sys.iaware.preloadoptenable 0
    [ "$(getprop persist.sys.iaware.touchdownpreloadenable)" != "0" ] && setprop persist.sys.iaware.touchdownpreloadenable 0
  fi
  # FCM keep-alive: re-assert on a wall-clock schedule (default 30 min), not
  # per-cycle; piggybacks the existing loop so no extra wakeup is created.
  # date(1) runs only every 90 cycles (~27s plugged / 15min unplugged).
  # Boot boost: PowerGenie re-pushes the stock google list during its own boot,
  # after our first assert -> dense re-asserts (60s x5) close that race window.
  if [ "$fcm_unlock" = "1" ] && [ $((cycle % 90)) -eq 0 ] && [ "$fcm_avail" = "1" ]; then
    now=$(date +%s)
    fcmint=${fcm_interval:-1800}
    [ "${fcm_boot_boost:-0}" -gt 0 ] && fcmint=60
    if [ $((now - fcm_last)) -ge $fcmint ]; then
      if fcm_assert; then
        fcm_last=$now
        [ "${fcm_boot_boost:-0}" -gt 0 ] && fcm_boot_boost=$((fcm_boot_boost-1))
      else
        fcm_last=$((now - $fcmint + 120))   # retry in ~2 min
      fi
    fi
  fi
  cycle=$((cycle + 1))

  # power: fight is only meaningful while a charger is connected. Fast poll
  # (0.3s) when plugged, deep 10s sleep otherwise -> ~zero idle cost.
  if [ "$online" != "1" ]; then
    sleep 10
    continue
  fi
  sleep "$poll_interval"
done
