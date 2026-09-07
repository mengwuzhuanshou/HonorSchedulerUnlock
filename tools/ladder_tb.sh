#!/system/bin/sh
exec > /data/local/tmp/ladder.log 2>&1
N=/proc/powerhal_cpu_ctrl/perfserv_freq
PKG=com.taobao.taobao
M4=/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
C4=/sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq
echo ==PREP==
am force-stop $PKG 2>/dev/null
sleep 1
monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
run_level() {
  lvl4=$1; lvl0=$2; tag=$3
  dumpsys gfxinfo $PKG reset >/dev/null 2>&1
  ( while :; do echo 4 300000 $lvl4 > $N; echo 0 300000 $lvl0 > $N; sleep 0.022; done ) & RP=$!
  i=0
  while [ $i -lt 30 ]; do
    input swipe 500 2100 500 700 200 >/dev/null 2>&1
    i=$((i+1))
  done
  echo "occ: $(cat $M4) $(cat $M4) $(cat $M4) cur=$(cat $C4)"
  kill $RP 2>/dev/null
  echo "==LEVEL $tag p4max=$lvl4 p0max=$lvl0=="
  dumpsys gfxinfo $PKG 2>/dev/null | grep -E "Total frames|Janky frames|50th|90th|95th|99th"
}
run_level 3500000 2700000 baseline
run_level 900000 2700000 p4-0.9G
run_level 800000 2700000 p4-0.8G
run_level 700000 2700000 p4-0.7G
run_level 600000 2700000 p4-0.6G
run_level 500000 2700000 p4-0.5G
run_level 600000 900000 p4-0.6G-p0-0.9G
echo 4 300000 3500000 > $N
echo 0 300000 2700000 > $N
echo ALL_DONE
