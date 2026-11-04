#!/system/bin/sh
. "${0%/*}/state.sh"
# 上一版把状态散在 /data/adb 顶层，两处都清掉（$ST 里是迁移后的名字）
rm -f /data/adb/honor_charge_unlock.* /data/adb/honor_charge_unlock_diag.txt
rm -rf /data/adb/camfix /data/adb/qrfix
rm -f $ST/pid $ST/paused
rm -f $ST/conf $ST/log
rm -f $ST/thermal_mounted
rm -f $ST/fcm
rm -f $ST/lsp
rm -f $ST/volte
rm -f $ST/qr
# qr_fix: drop the bind mount; the override file itself lives in the module
# tree (qrfix/) and disappears with the module. The stock /odm file is never
# written, so unmounting restores the stock camera config instantly.
umount /odm/etc/camera/airaw/facemaskconfig.xml 2>/dev/null
# smartae_target: same mechanism - the generated file lives under $ST/camfix
# (the stock /odm file is never written), so unmounting restores the stock AE
# target instantly and a reboot leaves nothing behind.
rm -f $ST/cam
umount /odm/etc/camera/smartae/back/SmartAE.xml 2>/dev/null
# sharpen_level (v2.2.0): drop the EE tuning-DB bind. The factory ISP_param.db
# was never written, so unmounting restores factory sharpening immediately (a
# -l fallback covers a HAL that still holds the mount during uninstall).
umount /odm/bin/crossbuild/DataSet/SQLiteModule/db/tuning_DB/calvrns_m010_ldy/ISP_param.db 2>/dev/null || \
  umount -l /odm/bin/crossbuild/DataSet/SQLiteModule/db/tuning_DB/calvrns_m010_ldy/ISP_param.db 2>/dev/null
rm -f $ST/shp $ST/camfix/ISP_param_lv*.db
# retired v2.0.0 sharpen_cut binds (older installs): unmount the rear-primary
# hdrp_mc.xml set so an uninstall does not keep that tuning until the next boot.
for shp_b in /odm/etc/camera/hdrplite /odm/etc/camera/rawhdr; do
  for shp_d in $(grep '_hpb_P=' "$shp_b/device.config" 2>/dev/null | sed 's|.*=||' | tr -d '\r'); do
    umount "${shp_d}hdrp_mc.xml" 2>/dev/null
  done
done
# beauty_cut / night_ev: same restore-on-unmount rule. The stock /odm files were never
# written, so unmounting returns the camera to factory tuning immediately - without
# this an uninstall would keep the modified tuning until the next reboot.
rm -f $ST/bty
umount /odm/etc/camera/hwbeauty/front/hwbeauty_params.xml 2>/dev/null
rm -f $ST/wng
umount /odm/etc/camera/featureConfig/dynamic_parameter.xml 2>/dev/null
# uw_exp_ms / uw_iso_gain (v2.1.0): drop the AE pline 311 and metastore binds.
# Neither factory file was written, so unmounting is a full restore; the HAL
# is restarted once so the next camera open maps the factory .so (the running
# process keeps its old mapping until it dies).
rm -f $ST/uwa
umount /odm/bin/crossbuild/DataSet/SQLiteModule/db/ae/ParameterDB_ae.db 2>/dev/null || \
  umount -l /odm/bin/crossbuild/DataSet/SQLiteModule/db/ae/ParameterDB_ae.db 2>/dev/null
umount /vendor/lib64/mt6993/libmtkcam_metastore.so 2>/dev/null || \
  umount -l /vendor/lib64/mt6993/libmtkcam_metastore.so 2>/dev/null
uw_pid=$(pidof camerahalserver 2>/dev/null); uw_pid=${uw_pid%% *}
[ -n "$uw_pid" ] && kill -TERM "$uw_pid" 2>/dev/null
# legacy v2.0.3 night_ev mount (supernight/config.xml) - unmount if still present
rm -f $ST/nev
umount /odm/etc/camera/supernight/config.xml 2>/dev/null
rm -rf $ST/camfix
# lsp_fix: if uninstalled inside the masked window (first ~minute after boot),
# the locale would otherwise stay en-US until the next boot. Restore as best
# effort (no-op when the restore already ran or the switch was off).
RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=resetprop
"$RP" ro.product.locale.language zh 2>/dev/null
"$RP" ro.product.locale.region CN 2>/dev/null
# thirdparty_home: same idea for the characteristics mask - put the stock value
# back if the module is removed inside that early window. The sidecar holds the
# value post-fs-data found; "default" is the stock value on this ROM either way.
tph_orig=$(head -n 1 $ST/tph_orig 2>/dev/null | tr -d '\r')
"$RP" ro.build.characteristics "${tph_orig:-default}" 2>/dev/null
rm -f $ST/tph $ST/tph_orig $ST/tph.done
# eid_guard: the bind source is under $ST/eidfix, so unmount before removing it -
# otherwise the patched lib stays mapped over /system until the next reboot and
# the factory EID check does not come back.
umount /system/lib64/liboeminfoInf_esim.so 2>/dev/null
rm -f $ST/eid
rm -rf $ST/eidfix /data/adb/eidfix
rm -f /data/vendor/thermal/thermal.conf
# FCM: probe url list lives only in system_server memory; PowerGenie re-pushes
# the stock google.com list on next boot. Restore immediately as best effort:
su 1000 -c 'service call pgservice 12 i32 6 i32 0 i32 2 s16 http://www.google.com s16 https://accounts.google.com' >/dev/null 2>&1
rm -rf "$ST"
# 系统充电路径会在下一次屏幕事件/温控刷新时自动恢复原值, 无需手动还原
# 热策略: 删除 /data/vendor/thermal/thermal.conf 后即回退到原厂 /vendor/etc/thermal/thermal.conf
