#!/system/bin/sh
pkill -f [f]reqgov.sh
sleep 0.5
echo ==AFTER_KILL==
for p in $(pgrep -f [f]reqgov.sh); do echo SURVIVOR $p; done
sh /data/adb/modules/freqgov_launch/service.sh
sleep 2
echo ==PROCS==
for p in $(pgrep -f [f]reqgov.sh); do
  printf "%s :: " $p
  tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null; echo
done
echo ==CPU_2S==
T0=0
for p in $(pgrep -f [f]reqgov.sh); do set -- $(cat /proc/$p/stat 2>/dev/null); T0=$((T0+${14}+${15})); done
for q in $(pgrep -f [l]ogcat); do set -- $(cat /proc/$q/stat 2>/dev/null); T0=$((T0+${14}+${15})); done
sleep 2
T1=0
for p in $(pgrep -f [f]reqgov.sh); do set -- $(cat /proc/$p/stat 2>/dev/null); T1=$((T1+${14}+${15})); done
for q in $(pgrep -f [l]ogcat); do set -- $(cat /proc/$q/stat 2>/dev/null); T1=$((T1+${14}+${15})); done
echo TICKS_2S=$((T1-T0))
echo ==FREQ==
cat /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
echo ALL_DONE
