#!/system/bin/sh
# Honor Charge Unlock - WebUI control bridge (called from webroot JS via ksu.exec)
# usage: webui_ctl.sh set <key> <value> | pause | resume | restart
CONF=/data/adb/honor_charge_unlock.conf
MODDIR=/data/adb/modules/honor_charge_unlock
PIDF=/data/adb/honor_charge_unlock.pid

do_restart() {
  [ -f "$PIDF" ] && kill -9 "$(cat $PIDF)" 2>/dev/null
  pkill -9 -f "[h]onor_charge_unlock/service.sh" 2>/dev/null
  pkill -9 -f "[A]ctivityManager:I" 2>/dev/null
  pkill -9 -f "sleep 99999999" 2>/dev/null
  pkill -9 -f "sleep 99999998" 2>/dev/null
  rm -f "$PIDF"
  nohup sh "$MODDIR/service.sh" >/dev/null 2>&1 &
}

case "$1" in
  set)
    k=$2; v=$3
    case "$k" in
      screen_on_unlock|unlock_when_screen_off|launch_boost|disable_preload)
        case "$v" in 0|1) ;; *) echo "ERR bad value"; exit 1 ;; esac ;;
      scroll_cap)
        case "$v" in 0|700000|800000|900000) ;; *) echo "ERR bad value"; exit 1 ;; esac ;;
      launch_boost_ms)
        case "$v" in ""|*[!0-9]*) echo "ERR bad value"; exit 1 ;; esac
        [ "$v" -gt 5000 ] && v=5000 ;;
      *) echo "ERR unknown key"; exit 1 ;;
    esac
    if grep -q "^$k=" "$CONF" 2>/dev/null; then
      sed -i "s/^$k=.*/$k=$v/" "$CONF"
    else
      echo "$k=$v" >> "$CONF"
    fi
    do_restart
    echo "OK $k=$v daemon reloading"
    ;;
  pause)
    touch /data/adb/honor_charge_unlock.paused
    echo "OK paused" ;;
  resume)
    rm -f /data/adb/honor_charge_unlock.paused
    echo "OK resumed" ;;
  restart)
    do_restart
    echo "OK restarted" ;;
  *)
    echo "usage: webui_ctl.sh set <key> <value> | pause | resume | restart" ;;
esac
