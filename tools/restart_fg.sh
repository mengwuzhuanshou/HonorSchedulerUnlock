#!/system/bin/sh
# safe restart: own cmdline has no 'freqgov.sh' substring, so pkill cannot self-match
pkill -f [f]reqgov.sh
sleep 0.5
cp /data/local/tmp/fgmod/freqgov.sh /data/adb/modules/freqgov_launch/freqgov.sh
chmod 755 /data/adb/modules/freqgov_launch/freqgov.sh
sh /data/adb/modules/freqgov_launch/service.sh
sleep 3
echo ==ALIVE==
pgrep -f [f]reqgov.sh
echo ==LOG==
tail -3 /data/cache/freqgov.log
echo ==CPU_CHECK==
P=$(pgrep -f [f]reqgov.sh | head -1)
A=$(cat /proc/$P/stat)
sleep 1
B=$(cat /proc/$P/stat)
set -- $B
u1=$14; s1=$15
set -- $A
u0=$14; s0=$15
echo CPU_TICKS_PER_SEC=$(( (u1+s1)-(u0+s0) ))
echo ==FREQ==
cat /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
