#!/system/bin/sh
# Live-deploy the camera/daemon knobs without a reboot (dev-side helper: tools/
# is not part of the flashable zip, so this file itself goes to the staging dir).
#
#   adb push <files below> /data/local/tmp/hcu_deploy/
#   adb push this file      /data/local/tmp/hcu_deploy/deploy_live.sh
#   adb shell su -c 'sh /data/local/tmp/hcu_deploy/deploy_live.sh'
#
# Ordering matters: the daemon is killed BEFORE the cp. `sh` reads a script
# incrementally, so cp-truncating a live service.sh would make the running
# daemon execute bytes from the middle of the new file. Starting it again is
# what re-runs the camfix bind-mount blocks (they sit above the boot wait).
STG=${1:-/data/local/tmp/hcu_deploy}
MOD=/data/adb/modules/honor_charge_unlock
PIDF=/data/adb/honor_charge_unlock/pid
FILES="service.sh webui_ctl.sh dashboard.sh module.prop uninstall.sh webroot/index.html camfix/beauty.awk camfix/hwbeauty_front_orig.xml camfix/SmartAE_back_orig.xml"

echo "== 1. stop daemon =="
[ -f "$PIDF" ] && kill -9 "$(cat $PIDF)" 2>/dev/null
pkill -9 -f "[h]onor_charge_unlock/service.sh" 2>/dev/null
pkill -9 -f "[A]ctivityManager:I" 2>/dev/null
pkill -9 -f "sleep 99999999" 2>/dev/null
pkill -9 -f "sleep 99999998" 2>/dev/null
rm -f "$PIDF"
sleep 1

echo "== 2. install =="
for f in $FILES; do
  [ -f "$STG/$f" ] || continue
  cp "$STG/$f" "$MOD/$f" 2>/dev/null || echo "CPFAIL $f"
done
mkdir -p "$MOD/ee_patch"
cp "$STG"/ee_patch/* "$MOD/ee_patch/" 2>/dev/null
chmod 755 "$MOD/service.sh" "$MOD/webui_ctl.sh" "$MOD/dashboard.sh" 2>/dev/null
chmod 644 "$MOD/module.prop" "$MOD/webroot/index.html" "$MOD"/camfix/* "$MOD"/ee_patch/* 2>/dev/null
restorecon -R "$MOD" 2>/dev/null
md5sum $MOD/service.sh $MOD/webui_ctl.sh $MOD/dashboard.sh $MOD/module.prop \
       $MOD/webroot/index.html $MOD/camfix/* $MOD/ee_patch/* 2>/dev/null

echo "== 3. start =="
# The UW marker is written by the last camfix block, so waiting for it proves
# all transforms/mounts finished. A plain sleep raced them (stock values showed).
rm -f /data/adb/honor_charge_unlock/uwa
nohup sh "$MOD/service.sh" >/dev/null 2>&1 &
i=0
while [ ! -s /data/adb/honor_charge_unlock/uwa ] && [ $i -lt 60 ]; do
  sleep 1; i=$((i + 1))
done
[ -s /data/adb/honor_charge_unlock/uwa ] && echo "camfix blocks done in ${i}s" \
  || echo "WARN camfix blocks not done after ${i}s"
PID=$(cat $PIDF 2>/dev/null)
if kill -0 "$PID" 2>/dev/null; then
  echo "alive pid=$PID cmd=$(tr '\0' ' ' < /proc/$PID/cmdline)"
else
  echo "DEAD pid=$PID"
fi

echo "== 4. requested vs live =="
for k in cam shp bty qr uw; do
  printf '%-4s %s\n' "$k" "$(tail -n 1 /data/adb/honor_charge_unlock/$k 2>/dev/null)"
done
UDB=/odm/bin/crossbuild/DataSet/SQLiteModule/db/ae/ParameterDB_ae.db
USO=/vendor/lib64/mt6993/libmtkcam_metastore.so
UE=$(od -An -tu4 -j 4265560 -N4 "$UDB" 2>/dev/null | tr -d ' \n')
UI=$(od -An -tu4 -j 4265568 -N4 "$UDB" 2>/dev/null | tr -d ' \n')
UW=$(od -An -tx4 -j 1335656 -N4 "$USO" 2>/dev/null | tr -d ' \n')
printf 'uw-eff exp=%sms iso=%s%% fps-word=%s\n' \
  "$((${UE:-0} / 1000))" "$((${UI:-0} * 100 / 72000))" "${UW:-?}"
printf 'back/SmartAE  %s\n' "$(grep -o "<Target>[0-9]*</Target>" /odm/etc/camera/smartae/back/SmartAE.xml 2>/dev/null | head -n 1)"
printf 'front-beauty  %s\n' "$(grep -a -m1 -o 'bty[0-9]*' /odm/etc/camera/hwbeauty/front/hwbeauty_params.xml 2>/dev/null)"
echo "== 5. camfix source labels =="
SLV=$(sed -n 's/^sharpen_level=//p' /data/adb/honor_charge_unlock/conf 2>/dev/null | head -n 1)
SDB=/odm/bin/crossbuild/DataSet/SQLiteModule/db/tuning_DB/calvrns_m010_ldy/ISP_param.db
ls -Z /data/adb/honor_charge_unlock/camfix/SmartAE_back.xml /data/adb/honor_charge_unlock/camfix/hwbeauty_front.xml \
      /data/adb/honor_charge_unlock/camfix/ISP_param_lv${SLV:-2}.db \
      /data/adb/honor_charge_unlock/camfix/uw_ae.db /data/adb/honor_charge_unlock/camfix/uw_metastore.so 2>/dev/null
printf 'sharpen DB   target_ino=%s gen_ino=%s\n' \
  "$(stat -c %i "$SDB" 2>/dev/null)" "$(stat -c %i /data/adb/honor_charge_unlock/camfix/ISP_param_lv${SLV:-2}.db 2>/dev/null)"
echo "== 5b. uw mounts =="
grep -E 'ParameterDB_ae\.db|libmtkcam_metastore\.so' /proc/mounts 2>/dev/null
echo "== 6. conf =="
grep -E '^(smartae_target|sharpen_level|beauty_cut)=' /data/adb/honor_charge_unlock/conf
echo ALL_DONE
