#!/system/bin/sh
rm -f /data/adb/honor_charge_unlock.pid /data/adb/honor_charge_unlock.paused
rm -f /data/adb/honor_charge_unlock.conf /data/adb/honor_charge_unlock.log
rm -f /data/adb/honor_charge_unlock.thermal_mounted
rm -f /data/vendor/thermal/thermal.conf
# 系统充电路径会在下一次屏幕事件/温控刷新时自动恢复原值, 无需手动还原
# 热策略: 删除 /data/vendor/thermal/thermal.conf 后即回退到原厂 /vendor/etc/thermal/thermal.conf
