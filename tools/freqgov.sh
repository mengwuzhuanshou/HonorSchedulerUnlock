#!/system/bin/sh
# FreqGov v2.0 - launch full-freq boost + optional scroll clamp
# RE basis: /proc/powerhal_cpu_ctrl/perfserv_freq write = <slot 0-7> <min> <max>
#   slot->cluster: 0-3->policy0, 4-6->policy4, 7->policy7; writes replace the
#   whole min/max QoS vote pair atomically; last writer wins; no TTL.
NODE=/proc/powerhal_cpu_ctrl/perfserv_freq
CONF=/data/adb/freqgov.conf
BOOST_MS=2000
SCROLL_MAX=900000
HOLD_TICKS=4
[ -f $CONF ] && . $CONF
[ $BOOST_MS -gt 5000 ] && BOOST_MS=5000
LOG=/data/cache/freqgov.log
P0MAX=2700000; P4MAX=3500000; P7MAX=4210000; PMIN=300000

# single instance: kill older copies
for p in /proc/[0-9]*; do
  [ "$p" = "/proc/$$" ] && continue
  read -r c < $p/cmdline 2>/dev/null || continue
  case $c in *freqgov.sh*) [ "${p#/proc/}" != "$$" ] && kill ${p#/proc/} 2>/dev/null ;; esac
done

# clean any vote pair left by a previous run
echo 0 $PMIN $P0MAX > $NODE
echo 4 $PMIN $P4MAX > $NODE
echo 7 $PMIN $P7MAX > $NODE

# zero-fork tick source: fifo + read -t timeout
FIF=/data/local/tmp/.freqgov_tick
rm -f $FIF; mkfifo $FIF 2>/dev/null
sleep 99999999 > $FIF & HP=$!
trap 'kill $HP 2>/dev/null' TERM INT EXIT

last_ev=X
touch_t=-99
tick=0
echo "$(date) freqgov start boost_ms=$BOOST_MS scroll_max=$SCROLL_MAX" > $LOG

logcat -b events -T 1 -s am_proc_start 2>/dev/null | while :; do
  tick=$((tick+1))
  boost=0
  if read -t 0.1 line; then
    case $line in *activity*) boost=1 ;; esac
  fi

  # scroll clamp state machine (touch = wakeup_sources event2 event_count delta)
  if [ $SCROLL_MAX -gt 0 ]; then
    if [ $((tick % 2)) -eq 0 ]; then
      ev=$(grep -m1 -s ^event2 /proc/wakeup_sources)
      case $ev in "$last_ev") ;; *) touch_t=$tick; last_ev=$ev ;; esac
    fi
    if [ $((tick - touch_t)) -lt $HOLD_TICKS ]; then
      echo 4 $PMIN $SCROLL_MAX > $NODE
      mode=SCROLL
    elif [ "$mode" = SCROLL ]; then
      echo 4 $PMIN $P4MAX > $NODE
      mode=IDLE
    fi
  fi

  # launch boost: pin min=max on all 3 clusters, renew 10Hz for BOOST_MS
  if [ $boost -eq 1 ]; then
    echo "$(date) boost tick=$tick" >> $LOG
    n=$((BOOST_MS / 100))
    while [ $n -gt 0 ]; do
      echo 0 $P0MAX $P0MAX > $NODE
      echo 4 $P4MAX $P4MAX > $NODE
      echo 7 $P7MAX $P7MAX > $NODE
      read -t 0.1 x < $FIF || :
      n=$((n-1))
    done
    echo 0 $PMIN $P0MAX > $NODE
    echo 4 $PMIN $P4MAX > $NODE
    echo 7 $PMIN $P7MAX > $NODE
    mode=IDLE
    d=0
    while [ $d -lt 8 ]; do read -t 0.02 line || break; d=$((d+1)); done
  fi
done
