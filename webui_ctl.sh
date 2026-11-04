#!/system/bin/sh
# Honor Charge Unlock - WebUI control bridge (called from webroot JS via ksu.exec)
# usage: webui_ctl.sh set <key> <value> | pause | resume | restart
MODDIR=/data/adb/modules/honor_charge_unlock
. "$MODDIR/state.sh"
st_init
CONF=$ST/conf
PIDF=$ST/pid

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
      screen_on_unlock|unlock_when_screen_off|launch_boost|disable_preload|fcm_unlock|vpn_lock|lsp_fix|thirdparty_home|volte_fix|qr_fix|eid_guard)
        case "$v" in 0|1) ;; *) echo "ERR bad value"; exit 1 ;; esac ;;
      region_mode)
        case "$v" in default|cn|overseas) ;; *) echo "ERR bad value"; exit 1 ;; esac ;;
      smartae_target)
        # rear-main AE luma target: 0 = off, sane band 100..250 (factory 200)
        case "$v" in ""|*[!0-9]*) echo "ERR bad value"; exit 1 ;; esac
        [ "$v" -ne 0 ] && { [ "$v" -lt 100 ] && v=100; [ "$v" -gt 250 ] && v=250; } ;;
      sharpen_level)
        # rear-main EE sharpening tier: 0 = off (factory), 1..4 (default x1.5)
        case "$v" in ""|*[!0-9]*) echo "ERR bad value"; exit 1 ;; esac
        [ "$v" -gt 4 ] && v=4 ;;
      beauty_cut)
        # front-beauty intensity cut in percent: 0 = off (factory curves), 1..90
        case "$v" in ""|*[!0-9]*) echo "ERR bad value"; exit 1 ;; esac
        [ "$v" -gt 90 ] && v=90 ;;
      scroll_cap)
        case "$v" in 0|700000|800000|900000) ;; *) echo "ERR bad value"; exit 1 ;; esac ;;
      uw_exp_ms)
        # ultra-wide low-light exposure ceiling: 0 = off (factory 200ms),
        # sane band 150..999; 200-499 selects the fps2 stage, 500+ fps1
        case "$v" in ""|*[!0-9]*) echo "ERR bad value"; exit 1 ;; esac
        [ "$v" -gt 0 ] && { [ "$v" -lt 150 ] && v=150; [ "$v" -gt 999 ] && v=999; } ;;
      uw_iso_gain)
        # ultra-wide AE table ISO scale in percent: factory 100, cap 250;
        # measured >=150 trades exposure for gain and shifts color red
        case "$v" in ""|*[!0-9]*) echo "ERR bad value"; exit 1 ;; esac
        [ "$v" -lt 100 ] && v=100
        [ "$v" -gt 250 ] && v=250 ;;
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
    touch $ST/paused
    echo "OK paused" ;;
  resume)
    rm -f $ST/paused
    echo "OK resumed" ;;
  restart)
    do_restart
    echo "OK restarted" ;;
  *)
    echo "usage: webui_ctl.sh set <key> <value> | pause | resume | restart" ;;
esac
