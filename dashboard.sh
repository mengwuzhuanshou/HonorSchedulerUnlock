#!/system/bin/sh
# Honor Charge Unlock - dashboard data collector
# Prints KEY=VALUE lines consumed by webroot/index.html
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
P=/sys/class/power_supply/primary_chg
DC=/sys/class/hw_power/charger
IF=/sys/class/hw_power/interface
AD=/sys/class/hw_power/adapter

gv() { cat "$1" 2>/dev/null | head -c 300; }
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
echo "MCS_CONN=$(ss -tn 2>/dev/null | grep -c ':5228')"

# unlock verdict: max of 3 samples over ~0.5s. The OS re-caps iin_thermal
# every ~4.4s and the daemon re-unlocks every 0.3s, so a single sample lands
# inside the suppressed window ~9% of the time and showed a false 被压制.
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
echo "FCM_STATE=$(tail -n 1 /data/adb/honor_charge_unlock.fcm 2>/dev/null)"
echo "VER=$(grep '^version=' /data/adb/modules/honor_charge_unlock/module.prop 2>/dev/null | cut -d= -f2)"
echo "TS=$(date +%s)"
