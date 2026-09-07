#!/system/bin/sh
rm -f /data/adb/honor_charge_unlock.pid /data/adb/honor_charge_unlock.paused
rm -f /data/adb/honor_charge_unlock.conf /data/adb/honor_charge_unlock.log
rm -f /data/adb/honor_charge_unlock.thermal_mounted
rm -f /data/adb/honor_charge_unlock.fcm
rm -f /data/vendor/thermal/thermal.conf
# FCM: probe url list lives only in system_server memory; PowerGenie re-pushes
# the stock google.com list on next boot. Restore immediately as best effort:
su 1000 -c 'service call pgservice 12 i32 6 i32 0 i32 2 s16 http://www.google.com s16 https://accounts.google.com' >/dev/null 2>&1
# 系统充电路径会在下一次屏幕事件/温控刷新时自动恢复原值, 无需手动还原
# 热策略: 删除 /data/vendor/thermal/thermal.conf 后即回退到原厂 /vendor/etc/thermal/thermal.conf
