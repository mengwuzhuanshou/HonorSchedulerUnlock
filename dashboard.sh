#!/system/bin/sh
# Honor Charge Unlock - dashboard data collector
# Prints KEY=VALUE lines consumed by webroot/index.html
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
P=/sys/class/power_supply/primary_chg
DC=/sys/class/hw_power/charger
IF=/sys/class/hw_power/interface
AD=/sys/class/hw_power/adapter

# WebUI exec may run unprivileged depending on KSU state; re-exec through su
# once (first denial falls back to limited data instead of looping)
if [ "$(id -u 2>/dev/null)" != "0" ] && [ "$2" != "rootretry" ]; then
  su -c "sh '$0' $1 rootretry" 2>/dev/null
  [ $? -eq 0 ] && exit 0
  # su denied/absent: fall through and serve whatever is globally readable
fi
gv() { cat "$1" 2>/dev/null | head -c 300; }
echo "EXEC_UID=$(id -u 2>/dev/null)"
ml() { gv "$1" | tr '\n' ';'; }
ub() { # uevent field
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

echo "B_STATUS=$(ub "$B/uevent" POWER_SUPPLY_STATUS)"
echo "B_TEMP=$(ub "$B/uevent" POWER_SUPPLY_TEMP)"
echo "B_CAP=$(ub "$B/uevent" POWER_SUPPLY_CAPACITY)"
echo "B_VOLT=$(ub "$B/uevent" POWER_SUPPLY_VOLTAGE_NOW)"
echo "B_CUR=$(ub "$B/uevent" POWER_SUPPLY_CURRENT_NOW)"
echo "B_CUR_NODE=$(cat $B/current_now 2>/dev/null | head -n 1)"
echo "B_CYCLE=$(ub "$B/uevent" POWER_SUPPLY_CYCLE_COUNT)"
echo "B_FCC=$(ub "$B/uevent" POWER_SUPPLY_CHARGE_FULL)"
echo "B_FCC_DESIGN=$(ub "$B/uevent" POWER_SUPPLY_CHARGE_FULL_DESIGN)"
echo "B_SOH=$(gv $B/state_of_health)"

echo "USB_ONLINE=$(gv $U/online)"
echo "USB_TYPE=$(gv $U/type)"
echo "USB_CMAX=$(gv $U/current_max)"
echo "USB_VMAX=$(gv $U/voltage_max)"

echo "PROTO=$(ml $IF/enable_charger | tr ';' ' ')"
echo "IIN_LIMIT=$(ml $IF/iin_limit | tr ';' ' ')"
echo "CHG_MODE=$(ml $IF/chg_mode | tr ';' ' ')"
echo "ADAP_VOLT=$(ml $IF/adap_volt | tr ';' ' ')"
echo "IBUS=$(ml $IF/ibus | tr ';' ' ')"
echo "HOTA=$(ml $IF/hota_iin_limit | tr ';' ' ')"

echo "ADP_TYPE=$(gv $AD/adapter_type)"
echo "ADP_SUPPORT=$(gv $AD/support_mode)"
echo "ADP_VMAX=$(gv $AD/max_volt)"
echo "ADP_IMAX=$(gv $AD/max_cur)"
echo "ADP_VENDOR=$(gv $AD/vendor_id)"
echo "ADP_FW=$(gv $AD/fwver)"
echo "ADP_POWER=$(gv $AD/power)"
# current input type: MTK usb_type marks the detected type with [brackets]
USBT_RAW=$(gv $P/usb_type)
echo "USBT_RAW=$USBT_RAW"
echo "PTYPE=$(cat $P/type 2>/dev/null | head -c 40)"
echo "UEV_TYPE=$(grep -oE 'POWER_SUPPLY_TYPE=[^ ]*' /sys/class/power_supply/usb/uevent 2>/dev/null | head -n1 | cut -d= -f2)"
CUR_IN=$(echo "$USBT_RAW" | grep -oE "\[[A-Za-z0-9]+\]" | head -n 1 | tr -d "[]")
echo "CUR_IN=$CUR_IN"
ADP_HS=$(cat $AD/adapter_type 2>/dev/null | head -n1 | tr -d "
"):$(cat $AD/support_mode 2>/dev/null | head -n1 | tr -d "
"):$(cat $AD/max_volt 2>/dev/null | head -n1 | tr -d "
"):$(cat $AD/max_cur 2>/dev/null | head -n1 | tr -d "
")
echo "ADP_HS=$ADP_HS"

for p in '' '_sc' '_hsc'; do
  d="$DC/direct_charger$p"
  n=$(echo "$p" | tr -d '_')
  [ -z "$n" ] && n=lvc
  echo "DC_${n}_IIN=$(gv $d/iin_thermal)"
  echo "DC_${n}_MAX=$(gv $d/iin_thermal_ichg_control)"
  echo "DC_${n}_SUCC=$(gv $d/direct_charge_succ)"
  echo "DC_${n}_DETECT=$(gv $d/adaptor_detect)"
  echo "DC_${n}_IADAPT=$(gv $d/iadapt)"
  echo "DC_${n}_RES=$(gv $d/full_path_resistance)"
done
echo "SC_STATE=$(gv $DC/direct_charger_sc/sc_state)"
echo "HSC_STATE=$(gv $DC/direct_charger_hsc/hsc_state)"
echo "LVC_STATE=$(gv $DC/direct_charger/lvc_state)"

echo "PC_ICC=$(gv $P/constant_charge_current)"
echo "PC_ICC_MAX=$(gv $P/constant_charge_current_max)"
echo "PC_AICR=$(gv $P/input_current_limit)"
echo "PC_CV=$(gv $P/constant_charge_voltage)"
echo "PC_TICC=$(gv $P/target_icc_uA)"
echo "PC_USTYPE=$(gv $P/usb_type)"
echo "PC_ONLINE=$(gv $P/online)"
echo "PC_STATUS=$(gv $P/status)"

# daemon: pidfile validated against cmdline, with pgrep fallback
# (a stale pidfile or a WebUI context that cannot read /data/adb must not
#  show 守护进程 ✕ while the daemon is actually running)
PID=$(cat /data/adb/honor_charge_unlock.pid 2>/dev/null)
DAEMON=0
if [ -n "$PID" ] && [ -d "/proc/$PID" ] && grep -q "service.sh" "/proc/$PID/cmdline" 2>/dev/null; then
  DAEMON=1
elif pgrep -f "[h]onor_charge_unlock/service.sh" >/dev/null 2>&1; then
  DAEMON=1
fi
echo "DAEMON=$DAEMON"
[ -f /data/adb/honor_charge_unlock.paused ] && echo "PAUSED=1" || echo "PAUSED=0"
[ -f /data/vendor/thermal/thermal.conf ] && echo "TPOLICY=1" || echo "TPOLICY=0"
[ -f /data/adb/honor_charge_unlock.thermal_mounted ] && echo "TMARK=1" || echo "TMARK=0"
[ -f /data/local/tmp/.hcu_lb_active ] && echo "LB_ACTIVE=1" || echo "LB_ACTIVE=0"
# MCS long-connection state (the wall/VPN layer, separate from the ROM-side probe unlock)
# VPN capture state: is com.google.android.gms inside a VPN's uid list, and is
# that VPN bypassable (MCS would unwrap it -> direct connect -> dead in CN)
GMS_UID=$(pm list packages -U 2>/dev/null | grep -E '^package:com.google.android.gms ' | head -n 1 | sed 's/.*uid://;s/[^0-9].*//')
echo "GMS_UID=${GMS_UID:-0}"
VPN_BYP=none
VPN_GMS_IN=0
VPN_BLOCK=$(dumpsys connectivity 2>/dev/null | grep -E 'VPN CONNECTED' | head -5)
if [ -n "$VPN_BLOCK" ]; then
  VPN_BYP=$(dumpsys connectivity 2>/dev/null | grep -m1 -oE 'bypassable=(true|false)' | cut -d= -f2)
  if [ -n "${GMS_UID:-}" ] && [ "$GMS_UID" -gt 10000 ] 2>/dev/null; then
    # NetworkAgentInfo lines are huge single lines: grep truncates them, awk does not
    VPN_GMS_IN=$(dumpsys connectivity 2>/dev/null | awk -v u="$GMS_UID" '/Uids: </{s=$0; sub(/.*Uids: </,"",s); sub(/>.*/,"",s); n=split(s,arr,","); for(i=1;i<=n;i++){gsub(/[{} ]/,"",arr[i]); m=split(arr[i],r,"-"); if(m==1&&r[1]+0==u){print 1;exit} if(m==2&&r[1]+0<=u&&u+0<=r[2]+0){print 1;exit}} print 0; exit}')
    [ -n "$VPN_GMS_IN" ] || VPN_GMS_IN=0
  fi
fi
echo "VPN_BYP=$VPN_BYP"
echo "VPN_GMS_IN=$VPN_GMS_IN"
# count MCS (5228) sockets owned by the GMS uid: >0 means the push channel is live
MCS_GMS=0
if [ -n "${GMS_UID:-}" ] && [ "$GMS_UID" -gt 10000 ] 2>/dev/null; then
  MCS_GMS=$(ss -tnpe 2>/dev/null | grep ':5228 ' | grep -c "uid:$GMS_UID")
fi
echo "MCS_GMS=$MCS_GMS"
SC3=0
i=0
while [ $i -lt 3 ]; do
  v=$(cat $DC/direct_charger_sc/iin_thermal 2>/dev/null)
  case $v in ''|*[!0-9]*) ;; *) [ "$v" -gt "$SC3" ] && SC3=$v ;; esac
  sleep 0.15
  i=$((i+1))
done
echo "DC_SC_IIN3=$SC3"

# conf keys for the WebUI switches
CONF=/data/adb/honor_charge_unlock.conf
cg() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n 1; }
echo "CONF_SCREEN_ON_UNLOCK=$(cg screen_on_unlock)"
echo "CONF_UNLOCK_OFF=$(cg unlock_when_screen_off)"
echo "CONF_LAUNCH_BOOST=$(cg launch_boost)"
echo "CONF_SCROLL_CAP=$(cg scroll_cap)"
echo "CONF_DISABLE_PRELOAD=$(cg disable_preload)"
echo "CONF_FCM_UNLOCK=$(cg fcm_unlock)"
echo "CONF_REGION_BYPASS=$(cg region_bypass)"
echo "CONF_VPN_LOCK=$(cg vpn_lock)"
echo "FCM_STATE=$(tail -n 1 /data/adb/honor_charge_unlock.fcm 2>/dev/null)"
# vpn_lock live state: off / idle (watching for a tunnel) / locked <pkg>
echo "VPN_LOCK_STATE=$(tail -n 1 /data/adb/honor_charge_unlock.vpn 2>/dev/null)"
echo "VER=$(grep '^version=' /data/adb/modules/honor_charge_unlock/module.prop 2>/dev/null | cut -d= -f2)"
echo "TS=$(date +%s)"
