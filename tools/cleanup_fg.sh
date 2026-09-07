#!/system/bin/sh
for p in $(pgrep -f [f]reqgov.sh); do
  kill -9 $p 2>/dev/null
  echo killed $p rc=$?
done
sleep 0.5
echo ==REMAIN==
for p in $(pgrep -f [f]reqgov.sh); do
  set -- $(cat /proc/$p/stat 2>/dev/null)
  echo "survivor $p state=${3} ppid=${4}"
done
echo ==START_ONE==
sh /data/adb/modules/freqgov_launch/service.sh
sleep 2
echo ==PROCS==
for p in $(pgrep -f [f]reqgov.sh); do
  set -- $(cat /proc/$p/stat 2>/dev/null)
  echo "$p state=${3} ppid=${4}"
done
echo ==CPU_2S==
T0=0; for p in $(pgrep -f [f]reqgov.sh); do set -- $(cat /proc/$p/stat 2>/dev/null); T0=$((T0+${14}+${15})); done
for q in $(pgrep -f [l]ogcat); do set -- $(cat /proc/$q/stat 2>/dev/null); T0=$((T0+${14}+${15})); done
sleep 2
T1=0; for p in $(pgrep -f [f]reqgov.sh); do set -- $(cat /proc/$p/stat 2>/dev/null); T1=$((T1+${14}+${15})); done
for q in $(pgrep -f [l]ogcat); do set -- $(cat /proc/$q/stat 2>/dev/null); T1=$((T1+${14}+${15})); done
echo TICKS_2S=$((T1-T0))
echo ALL_DONE
