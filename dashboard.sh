#!/system/bin/sh
# Honor Charge Unlock - dashboard data collector (batch-read rewrite, candidate)
# Prints KEY=VALUE lines consumed by webroot/index.html
#
# $1 = quick | full (default full, so any caller that passes nothing keeps the
# old behaviour):
#   quick: charging nodes + conf echo + camera live readouts - the panel polls
#          this every 3 s, so it has to stay cheap.
#   full:  quick + the binder-costly identity rows (telephony registry dump,
#          connectivity dump, pm, ss, the eSIM sha, the /proc maps scan). Those
#          change per boot/SIM/adapter event, not per second.
#
# Why one awk process reads the nodes: every $(cat node) is two fork+exec on
# toybox (measured 8.9 ms for one command substitution, 12.3 ms for
# cat|head, 0.2 ms for a builtin). The per-field readers cost ~250 forks per
# poll - about 2 s of pure process spawning on this SoC, which is what stalled
# the WebUI when an input got focus or Apply was tapped.
MODDIR=${0%/*}
. "$MODDIR/state.sh"          # read-only here: never migrates from the panel
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
P=/sys/class/power_supply/primary_chg
DC=/sys/class/hw_power/charger
IF=/sys/class/hw_power/interface
AD=/sys/class/hw_power/adapter
CONF=$ST/conf
MODPROP=/data/adb/modules/honor_charge_unlock/module.prop

SCOPE=full
case "$1" in quick|full) SCOPE=$1 ;; esac

# WebUI exec may run unprivileged depending on KSU state; re-exec through su
# once (first denial falls back to limited data instead of looping)
if [ "$(id -u 2>/dev/null)" != "0" ] && [ "$2" != "rootretry" ]; then
  su -c "sh '$0' $1 rootretry" 2>/dev/null
  [ $? -eq 0 ] && exit 0
  # su denied/absent: fall through and serve whatever is globally readable
fi
echo "EXEC_UID=$(id -u 2>/dev/null)"

# ---- bulk reader -----------------------------------------------------------
# list format: KEY|path|mode
#   mode empty  -> first line, cut at 300 chars   (was: cat | head -c 300)
#   mode m      -> all lines joined by one space  (was: cat | tr '\n' ';' | tr ';' ' ')
#   mode l      -> last line                       (was: tail -n 1)
#   mode FIELD  -> value of the first line starting with "FIELD="
#                 (was: sed -n "s/^FIELD=//p" | head -n 1)
awk '
BEGIN { FS = "|" }
NF < 2 { next }
{
  key = $1; path = $2; mode = $3
  if (mode == "m") {
    out = ""; sep = ""
    while ((getline ln < path) > 0) { if (ln == "") continue; out = out sep ln; sep = " " }
    close(path); out = substr(out, 1, 300)
  } else if (mode == "l") {
    out = ""
    while ((getline ln < path) > 0) out = ln
    close(path)
  } else if (mode == "") {
    if ((getline ln < path) > 0) out = substr(ln, 1, 300); else out = ""
    close(path)
  } else {
    pre = mode "="; n = length(pre); out = ""
    while ((getline ln < path) > 0) if (index(ln, pre) == 1) { out = substr(ln, n + 1); break }
    close(path)
  }
  v[key] = out
  print key "=" out
}
END {
  # MTK usb_type marks the detected type with [brackets]
  if (match(v["USBT_RAW"], /\[[A-Za-z0-9]+\]/))
    print "CUR_IN=" substr(v["USBT_RAW"], RSTART + 1, RLENGTH - 2)
  else
    print "CUR_IN="
  print "ADP_HS=" v["ADP_TYPE"] ":" v["ADP_SUPPORT"] ":" v["ADP_VMAX"] ":" v["ADP_IMAX"]
  # The ceiling actually applied is primary_chg/input_current_limit: the kernel
  # programs the charge IC from the arbitration result (M:ilim eff = min over the
  # enabled voters), so that is the number worth naming a lane after.
  # target_aicr_uA is not it - same-frame reads at 2026-11-03 21:53 UTC were
  # input_current_limit=1200000 while target_aicr_uA=1000000 and our own dcp row
  # already read 20000, so a lane matched against the target names a lane that is
  # driving nothing. Report every row numerically equal to the applied value (mA):
  # one number can sit in two rows (1200 matched both the vendor dcp thermal vote
  # and wl_hsc), so this is arithmetic, not "the lane the module unlocked".
  t = v["PC_AICR"] + 0; l = v["IIN_LIMIT"]
  if (t <= 0 || l == "") print "AICR_SLOT=?"
  else {
    n = split(l, a, " "); hit = ""
    for (i = 1; i < n; i += 2) if (a[i + 1] + 0 == t / 1000) hit = hit ((hit == "") ? "" : ",") a[i]
    print "AICR_SLOT=" (hit == "" ? "?" : hit)
  }
}' 2>/dev/null <<EOF
B_STATUS|$B/uevent|POWER_SUPPLY_STATUS
B_TEMP|$B/uevent|POWER_SUPPLY_TEMP
B_CAP|$B/uevent|POWER_SUPPLY_CAPACITY
B_VOLT|$B/uevent|POWER_SUPPLY_VOLTAGE_NOW
B_CUR|$B/uevent|POWER_SUPPLY_CURRENT_NOW
B_CYCLE|$B/uevent|POWER_SUPPLY_CYCLE_COUNT
B_FCC|$B/uevent|POWER_SUPPLY_CHARGE_FULL
B_FCC_DESIGN|$B/uevent|POWER_SUPPLY_CHARGE_FULL_DESIGN
UEV_TYPE|$U/uevent|POWER_SUPPLY_TYPE
B_CUR_NODE|$B/current_now
B_SOH|$B/state_of_health
USB_ONLINE|$U/online
USB_TYPE|$U/type
USB_CMAX|$U/current_max
USB_VMAX|$U/voltage_max
ADP_TYPE|$AD/adapter_type
ADP_SUPPORT|$AD/support_mode
ADP_VMAX|$AD/max_volt
ADP_IMAX|$AD/max_cur
ADP_VENDOR|$AD/vendor_id
ADP_FW|$AD/fwver
ADP_POWER|$AD/power
USBT_RAW|$P/usb_type
PTYPE|$P/type
PC_ICC|$P/constant_charge_current
PC_ICC_MAX|$P/constant_charge_current_max
PC_AICR|$P/input_current_limit
PC_CV|$P/constant_charge_voltage
PC_TICC|$P/target_icc_uA
PC_TAICR|$P/target_aicr_uA
PC_CMAX|$P/current_max
PC_VMAX|$P/voltage_max
PC_LOCK|$P/lock_icc_and_aicr_en
PC_USTYPE|$P/usb_type
PC_ONLINE|$P/online
PC_STATUS|$P/status
SC_STATE|$DC/direct_charger_sc/sc_state
HSC_STATE|$DC/direct_charger_hsc/hsc_state
LVC_STATE|$DC/direct_charger/lvc_state
PROTO|$IF/enable_charger|m
IIN_LIMIT|$IF/iin_limit|m
CHG_MODE|$IF/chg_mode|m
ADAP_VOLT|$IF/adap_volt|m
IBUS|$IF/ibus|m
HOTA|$IF/hota_iin_limit|m
IF_VBUS|$IF/vbus|m
DC_lvc_IIN|$DC/direct_charger/iin_thermal
DC_lvc_MAX|$DC/direct_charger/iin_thermal_ichg_control
DC_lvc_SUCC|$DC/direct_charger/direct_charge_succ
DC_lvc_DETECT|$DC/direct_charger/adaptor_detect
DC_lvc_IADAPT|$DC/direct_charger/iadapt
DC_lvc_RES|$DC/direct_charger/full_path_resistance
DC_sc_IIN|$DC/direct_charger_sc/iin_thermal
DC_sc_MAX|$DC/direct_charger_sc/iin_thermal_ichg_control
DC_sc_SUCC|$DC/direct_charger_sc/direct_charge_succ
DC_sc_DETECT|$DC/direct_charger_sc/adaptor_detect
DC_sc_IADAPT|$DC/direct_charger_sc/iadapt
DC_sc_RES|$DC/direct_charger_sc/full_path_resistance
DC_hsc_IIN|$DC/direct_charger_hsc/iin_thermal
DC_hsc_MAX|$DC/direct_charger_hsc/iin_thermal_ichg_control
DC_hsc_SUCC|$DC/direct_charger_hsc/direct_charge_succ
DC_hsc_DETECT|$DC/direct_charger_hsc/adaptor_detect
DC_hsc_IADAPT|$DC/direct_charger_hsc/iadapt
DC_hsc_RES|$DC/direct_charger_hsc/full_path_resistance
CONF_SCREEN_ON_UNLOCK|$CONF|screen_on_unlock
CONF_UNLOCK_OFF|$CONF|unlock_when_screen_off
CONF_LAUNCH_BOOST|$CONF|launch_boost
CONF_SCROLL_CAP|$CONF|scroll_cap
CONF_MAX_IIN|$CONF|max_iin
CONF_IFACE_LANES|$CONF|iface_lanes
CONF_DISABLE_PRELOAD|$CONF|disable_preload
CONF_FCM_UNLOCK|$CONF|fcm_unlock
CONF_REGION_MODE|$CONF|region_mode
CONF_VPN_LOCK|$CONF|vpn_lock
CONF_LSP_FIX|$CONF|lsp_fix
CONF_THIRDPARTY_HOME|$CONF|thirdparty_home
CONF_VOLTE_FIX|$CONF|volte_fix
CONF_QR_FIX|$CONF|qr_fix
CONF_EID_GUARD|$CONF|eid_guard
CONF_SMARTAE_TARGET|$CONF|smartae_target
CONF_SHARPEN_LVL|$CONF|sharpen_level
CONF_BEAUTY_CUT|$CONF|beauty_cut
CONF_UW_EXP_MS|$CONF|uw_exp_ms
CONF_UW_ISO_GAIN|$CONF|uw_iso_gain
FCM_STATE|$ST/fcm|l
VPN_LOCK_STATE|$ST/vpn|l
LSP_STATE|$ST/lsp|l
TPH_STATE|$ST/tph|l
VOLTE_STATE|$ST/volte|l
QR_STATE|$ST/qr|l
EID_STATE|$ST/eid|l
CAM_STATE|$ST/cam|l
SHP_STATE|$ST/shp|l
BTY_STATE|$ST/bty|l
UW_STATE|$ST/uwa|l
VER|$MODPROP|version
EOF

# daemon: pidfile validated against cmdline, with pgrep fallback
# (a stale pidfile or a WebUI context that cannot read /data/adb must not
#  show 守护进程 ✕ while the daemon is actually running)
PID=$(head -n 1 "$ST/pid" 2>/dev/null)
DAEMON=0
if [ -n "$PID" ] && [ -d "/proc/$PID" ] && grep -q "service.sh" "/proc/$PID/cmdline" 2>/dev/null; then
  DAEMON=1
elif pgrep -f "[h]onor_charge_unlock/service.sh" >/dev/null 2>&1; then
  DAEMON=1
fi
echo "DAEMON=$DAEMON"
[ -f $ST/paused ] && echo "PAUSED=1" || echo "PAUSED=0"
[ -f /data/vendor/thermal/thermal.conf ] && echo "TPOLICY=1" || echo "TPOLICY=0"
[ -f $ST/thermal_mounted ] && echo "TMARK=1" || echo "TMARK=0"
[ -f /data/local/tmp/.hcu_lb_active ] && echo "LB_ACTIVE=1" || echo "LB_ACTIVE=0"

# live region identity in the prop area right now - post-fs-data pins these at
# boot, so a mode change shows up here only after the next reboot
echo "REGION_OPTB=$(getprop msc.config.optb 2>/dev/null)"
echo "REGION_LOCALE=$(getprop ro.product.locale.region 2>/dev/null)"
# characteristics is the thirdparty_home lever: post-fs-data masks it to "phone"
# for the pre-zygote window only, so on a normal boot this reads the stock value
echo "CHARS=$(getprop ro.build.characteristics 2>/dev/null)"

# ---- camera live readouts ---------------------------------------------------
# What the HAL actually resolves right now through /odm and /vendor, so the
# panel shows the effective value and not the requested one. Bind mounts show
# up here because every path is read through its mount point.
echo "EFF_TARGET=$(awk '/<Target>/ && match($0, /<Target>[0-9]+<\/Target>/) { print substr($0, RSTART + 8, RLENGTH - 17); exit }' /odm/etc/camera/smartae/back/SmartAE.xml 2>/dev/null)"
SHP_LVL=$(awk -F= '$1 == "sharpen_level" { print $2; exit }' "$CONF" 2>/dev/null)
SHP_GEN=$ST/camfix/ISP_param_lv$SHP_LVL.db
SHP_TGT=/odm/bin/crossbuild/DataSet/SQLiteModule/db/tuning_DB/calvrns_m010_ldy/ISP_param.db
# An inode compare is bind-mount aware and cheap enough for the panel poll;
# hashing the 12MB DB on every poll is not.
if [ -f "$SHP_GEN" ] && [ "$(stat -c %i "$SHP_TGT" 2>/dev/null)" = "$(stat -c %i "$SHP_GEN" 2>/dev/null)" ]; then
  echo "EFF_SHARPEN=$SHP_LVL"
else
  echo "EFF_SHARPEN="
fi
echo "EFF_BEAUTY=$(awk 'match($0, /bty[0-9]+/) { print substr($0, RSTART + 3, RLENGTH - 3); exit }' /odm/etc/camera/hwbeauty/front/hwbeauty_params.xml 2>/dev/null)"
echo "EFF_BEAUTY_LP=$(awk 'match($0, /bty[0-9]+/) { print substr($0, RSTART + 3, RLENGTH - 3); exit }' /odm/etc/camera/hwbeauty/front/hwbeauty_params_lp.xml 2>/dev/null)"
UW_DB=/odm/bin/crossbuild/DataSet/SQLiteModule/db/ae/ParameterDB_ae.db
UW_SO=/vendor/lib64/mt6993/libmtkcam_metastore.so
UW_E=$(od -An -tu4 -j 4265560 -N4 "$UW_DB" 2>/dev/null | tr -d ' \n')
case "$UW_E" in ''|*[!0-9]*) ;; *) echo "EFF_UW_EXP=$((UW_E / 1000))" ;; esac
UW_I=$(od -An -tu4 -j 4265568 -N4 "$UW_DB" 2>/dev/null | tr -d ' \n')
case "$UW_I" in ''|*[!0-9]*) ;; *) echo "EFF_UW_ISO=$((UW_I * 100 / 72000))" ;; esac
UW_W=$(od -An -tx4 -j 1335656 -N4 "$UW_SO" 2>/dev/null | tr -d ' \n')
case "$UW_W" in
  528000a8|528000A8) echo "EFF_UW_FPS=5" ;;
  52800048) echo "EFF_UW_FPS=2" ;;
  52800028) echo "EFF_UW_FPS=1" ;;
  *) echo "EFF_UW_FPS=0" ;;
esac

[ "$SCOPE" = quick ] && exit 0

# ---- full scope: the binder-costly identity rows ----------------------------
GMS_UID=$(pm list packages -U 2>/dev/null | grep -m1 -oE 'com\.google\.android\.gms uid:[0-9]+' | sed 's/.*uid://')
echo "GMS_UID=${GMS_UID:-0}"
VPN_BYP=none
VPN_GMS_IN=0
# one dumpsys call and three reads of its file: the old shape paid the binder
# dump itself three times per poll
CV=/data/local/tmp/.hcu_conn
dumpsys connectivity > "$CV" 2>/dev/null
if grep -q 'VPN CONNECTED' "$CV" 2>/dev/null; then
  VPN_BYP=$(grep -m1 -oE 'bypassable=(true|false)' "$CV" 2>/dev/null | cut -d= -f2)
  if [ -n "${GMS_UID:-}" ] && [ "$GMS_UID" -gt 10000 ] 2>/dev/null; then
    # NetworkAgentInfo lines are huge single lines: grep truncates them, awk does not
    VPN_GMS_IN=$(awk -v u="$GMS_UID" '/Uids: </{s=$0; sub(/.*Uids: </,"",s); sub(/>.*/,"",s); n=split(s,arr,","); for(i=1;i<=n;i++){gsub(/[{} ]/,"",arr[i]); m=split(arr[i],r,"-"); if(m==1&&r[1]+0==u){print 1;exit} if(m==2&&r[1]+0<=u&&u+0<=r[2]+0){print 1;exit}} print 0; exit}' "$CV" 2>/dev/null)
    [ -n "$VPN_GMS_IN" ] || VPN_GMS_IN=0
  fi
fi
rm -f "$CV"
echo "VPN_BYP=$VPN_BYP"
echo "VPN_GMS_IN=$VPN_GMS_IN"
# count MCS (5228) sockets owned by the GMS uid: >0 means the push channel is live
MCS_GMS=0
if [ -n "${GMS_UID:-}" ] && [ "$GMS_UID" -gt 10000 ] 2>/dev/null; then
  MCS_GMS=$(ss -tnpe 2>/dev/null | awk -v u="$GMS_UID" 'index($0, ":5228 ") && index($0, "uid:" u) { n++ } END { print n + 0 }')
fi
echo "MCS_GMS=$MCS_GMS"

# per-SIM real signal readout (v1.9.7): panel-only cost — these few greps run
# just while the WebUI is polling; closing the panel costs nothing. (The
# registry dump is ~370KB, over mksh's 128KB single-argument limit, so it goes
# through a temp file and is never passed as a printf/echo argument.)
RG=/data/local/tmp/.hcu_reg
dumpsys telephony.registry > "$RG" 2>/dev/null
echo "SIG_OPS=$(getprop gsm.operator.alpha 2>/dev/null)"
echo "SIG_TYPES=$(getprop gsm.network.type 2>/dev/null)"
SL=$(grep -oE 'mLte=CellSignalStrengthLte: rssi=[^ ]+ rsrp=[^ ]+ rsrq=[^ ]+ rssnr=[^ ]+' "$RG")
SB=$(grep -oE 'mCellIdentity=CellIdentityLte:\{[^{]*mBands=\[[0-9]+\]' "$RG" | grep -oE '\[[0-9]+\]')
SN=$(grep -oE 'mNr=CellSignalStrengthNr:\{[^}]*ssRsrp = [0-9-]+' "$RG" | grep -oE 'ssRsrp = [0-9-]+' | cut -d' ' -f3)
echo "SIG0_LTE=$(printf '%s\n' "$SL" | sed -n 1p)"
echo "SIG1_LTE=$(printf '%s\n' "$SL" | sed -n 2p)"
echo "SIG0_BAND=$(printf '%s\n' "$SB" | sed -n 1p | tr -d '[]')"
echo "SIG1_BAND=$(printf '%s\n' "$SB" | sed -n 2p | tr -d '[]')"
echo "SIG0_NR=$(printf '%s\n' "$SN" | sed -n 1p | tr -d ' ')"
echo "SIG1_NR=$(printf '%s\n' "$SN" | sed -n 2p | tr -d ' ')"
# QCI per SIM from the bearer states: 5=IMS(VoLTE) signaling, 6/8/9=internet.
# QCI 5 appearing on a SIM == its IMS bearer is actually established.
Q=$(grep -oE 'mPreciseDataConnectionStates=\{.*' "$RG")
echo "SIG0_QCI=$(printf '%s\n' "$Q" | sed -n 1p | grep -oE 'qosClassId=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' '+' | sed 's/+*$//')"
echo "SIG1_QCI=$(printf '%s\n' "$Q" | sed -n 2p | grep -oE 'qosClassId=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' '+' | sed 's/+*$//')"
# eid_guard live state: off / on / unsupported / mount-failed / patch-failed /
# missing. EID_LIVE reads the sha through the /system path, so it reports what
# com.android.phone would actually dlopen: "patched" only while the bind mount is
# live, "factory" the moment it is gone (same trick as the camfix read-back).
EID_TGT=/system/lib64/liboeminfoInf_esim.so
EID_LIVE=$(sha256sum "$EID_TGT" 2>/dev/null | cut -c1-8)
if [ "$EID_LIVE" = "faf613c5" ]; then echo "EID_LIVE=patched"
elif [ "$EID_LIVE" = "02fa215f" ]; then echo "EID_LIVE=factory"
else echo "EID_LIVE=absent"; fi
# who has the lib mapped: the class only loads on a SIM state change, so "none"
# is the normal resting state (and the reason a toggle can land without a reboot).
# One grep over the whole glob - a per-pid loop would run on every panel poll.
echo "EID_MAPPED=$(grep -al liboeminfoInf_esim /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3 | tr '\n' ' ')"

echo "TS=$(date +%s)"
