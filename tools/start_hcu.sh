#!/system/bin/sh
[ -f /data/adb/honor_charge_unlock.pid ] && kill -9 $(cat /data/adb/honor_charge_unlock.pid) 2>/dev/null
pkill -9 -f [h]onor_charge_unlock/service.sh 2>/dev/null
pkill -9 -f [A]ctivityManager:I 2>/dev/null
pkill -9 -f [a]m_proc_start 2>/dev/null
for p in $(pgrep -f [f]reqgov.sh); do kill -9 $p 2>/dev/null; done
sleep 0.5
rm -f /data/adb/honor_charge_unlock.pid
echo ==REMAIN==
pgrep -f [h]onor_charge_unlock/service.sh || echo clean
echo ==START_DETACHED==
nohup sh /data/adb/modules/honor_charge_unlock/service.sh >/dev/null 2>&1 &
sleep 12
echo ==PROCS==
pgrep -f [h]onor_charge_unlock/service.sh
echo ==FREQ_SMOKE==
am force-stop com.hihonor.android.totemweather
sleep 1
monkey -p com.hihonor.android.totemweather -c android.intent.category.LAUNCHER 1 2>/dev/null
C7=/sys/devices/system/cpu/cpufreq/policy7/scaling_cur_freq
X7=/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq
C4=/sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq
X4=/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
for i in 1 2 3 4 5 6 7 8; do echo p7=$(cat $C7)/$(cat $X7) p4=$(cat $C4)/$(cat $X4); sleep 0.3; done
echo ==LOGLINE==
tail -4 /data/adb/honor_charge_unlock.log 2>/dev/null
echo ALL_DONE
