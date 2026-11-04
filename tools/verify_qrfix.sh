#!/system/bin/sh
echo "qr状态: $(cat /data/adb/honor_charge_unlock/qr 2>/dev/null)"
echo "挂载: $(grep facemaskconfig /proc/mounts | cut -c1-80)"
echo "odm路径md5: $(md5sum /odm/etc/camera/airaw/facemaskconfig.xml 2>/dev/null)"
echo "模块源md5: $(md5sum /data/adb/modules/honor_charge_unlock/qrfix/facemaskconfig.xml 2>/dev/null)"
echo "service.d残留: [$(ls /data/adb/service.d/ 2>/dev/null | tr '\n' ' ')]"
if [ -d /data/adb/qrfix ]; then echo "旧qrfix目录: 仍存在"; else echo "旧qrfix目录: 已删"; fi
echo "conf: $(grep qr_fix /data/adb/honor_charge_unlock/conf)"
p=$(cat /data/adb/honor_charge_unlock/pid 2>/dev/null)
echo "守护pid: $p alive=$(test -n "$p" && test -d /proc/$p && echo yes || echo no)"
echo "版本: $(grep '^version=' /data/adb/modules/honor_charge_unlock/module.prop)"
