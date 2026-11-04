#!/system/bin/sh
# one-shot MCS/FCM diagnostic for the panel chip (read-only)
echo "--- date"; date
echo "--- fcm state file"; ls -l /data/adb/honor_charge_unlock/fcm; cat /data/adb/honor_charge_unlock/fcm
echo "--- gms uid"; pm list packages -U 2>/dev/null | grep -a 'package:com.google.android.gms '
echo "--- any 5228 sockets"; ss -tnp 2>/dev/null | grep -a ':5228' | head -5
echo "--- established count all"; ss -tn state established 2>/dev/null | wc -l
echo "--- vpn present?"; dumpsys connectivity 2>/dev/null | grep -a -m3 -E 'Current^|NETWORK TYPE VPN|TYPE_VPN'
echo "--- gms proc"; pidof com.google.android.gms
echo "--- fcm log tail"; grep -a -E 'fcm|mcs|5228|probe' /data/adb/honor_charge_unlock/log 2>/dev/null | tail -12
