#!/system/bin/sh
# install-time script (Magisk & KernelSU)
SKIPUNZIP=0

ui_print "- Honor Scheduler Unlock (MTK) / 荣耀调度解锁"
ui_print "- 设备: $(getprop ro.product.marketname 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
ui_print "- 系统: $(getprop ro.build.version.magic 2>/dev/null) / Android $(getprop ro.build.version.release 2>/dev/null)"

if [ ! -d /sys/class/hw_power/charger/direct_charger_hsc ]; then
  ui_print "! 未找到荣耀直充节点 direct_charger_hsc"
  ui_print "! 本模块面向荣耀 MTK 平台, 继续安装也可以, 但可能无效"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755

ui_print "- 守护进程将在开机完成后自动运行"
ui_print "- 配置文件: /data/adb/honor_charge_unlock.conf"
ui_print "- 日志(需 verbose=1): /data/adb/honor_charge_unlock.log"
ui_print "- 亮屏/全时段充电解锁已启用"
ui_print "- WebUI 仪表盘: KernelSU 管理器 -> 本模块 -> WebUI"
