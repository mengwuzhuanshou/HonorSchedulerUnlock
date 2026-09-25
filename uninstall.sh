#!/system/bin/sh
rm -f /data/adb/honor_charge_unlock.pid /data/adb/honor_charge_unlock.paused
rm -f /data/adb/honor_charge_unlock.conf /data/adb/honor_charge_unlock.log
rm -f /data/adb/honor_charge_unlock.thermal_mounted
rm -f /data/adb/honor_charge_unlock.fcm
rm -f /data/adb/honor_charge_unlock.lsp
rm -f /data/adb/honor_charge_unlock.volte
rm -f /data/adb/honor_charge_unlock.qr
# qr_fix: drop the bind mount; the override file itself lives in the module
# tree (qrfix/) and disappears with the module. The stock /odm file is never
# written, so unmounting restores the stock camera config instantly.
umount /odm/etc/camera/airaw/facemaskconfig.xml 2>/dev/null
# lsp_fix: if uninstalled inside the masked window (first ~minute after boot),
# the locale would otherwise stay en-US until the next boot. Restore as best
# effort (no-op when the restore already ran or the switch was off).
RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=resetprop
"$RP" ro.product.locale.language zh 2>/dev/null
"$RP" ro.product.locale.region CN 2>/dev/null
rm -f /data/vendor/thermal/thermal.conf
# FCM: probe url list lives only in system_server memory; PowerGenie re-pushes
# the stock google.com list on next boot. Restore immediately as best effort:
su 1000 -c 'service call pgservice 12 i32 6 i32 0 i32 2 s16 http://www.google.com s16 https://accounts.google.com' >/dev/null 2>&1
# 系统充电路径会在下一次屏幕事件/温控刷新时自动恢复原值, 无需手动还原
# 热策略: 删除 /data/vendor/thermal/thermal.conf 后即回退到原厂 /vendor/etc/thermal/thermal.conf
