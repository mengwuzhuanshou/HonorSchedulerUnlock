#!/system/bin/sh
# read-only sampler: how often the effective charge limit reads below the panel's
# 11000 threshold (chip flips to 被压制 when a poll lands in such a window)
DC=/sys/class/hw_power/charger
i=0; low=0; tot=0; mn=99999; mx=0
while [ $i -lt 60 ]; do
  a=$(cat $DC/direct_charger_sc/iin_thermal 2>/dev/null | tr -d ' \n')
  b=$(cat $DC/direct_charger_hsc/iin_thermal 2>/dev/null | tr -d ' \n')
  case $a in ''|*[!0-9]*) a=0 ;; esac
  case $b in ''|*[!0-9]*) b=0 ;; esac
  v=$a; [ "$b" -gt "$v" ] && v=$b
  tot=$((tot+1))
  [ "$v" -lt 11000 ] && low=$((low+1))
  [ "$v" -lt "$mn" ] && mn=$v
  [ "$v" -gt "$mx" ] && mx=$v
  i=$((i+1)); sleep 0.5
done
echo "samples=$tot below_11000=$low min=$mn max=$mx"
