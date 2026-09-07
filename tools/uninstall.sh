#!/system/bin/sh
pkill -f freqgov.sh 2>/dev/null
N=/proc/powerhal_cpu_ctrl/perfserv_freq
echo 0 300000 2700000 > $N 2>/dev/null
echo 4 300000 3500000 > $N 2>/dev/null
echo 7 300000 4210000 > $N 2>/dev/null
rm -f /data/local/tmp/.freqgov_tick /data/adb/freqgov.conf
