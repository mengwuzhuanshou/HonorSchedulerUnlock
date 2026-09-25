#!/system/bin/sh
# Honor Charge Unlock - post-fs-data stage
# Only cleans up. The charge unlock itself is done by service.sh's runtime
# daemon; nothing here can stall boot.
MODDIR=${0%/*}

CONF=/data/adb/honor_charge_unlock.conf
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

# remove a leftover thermal policy override from older versions.
# WARNING: do NOT re-add this. Delivering a vtskin-DISABLING policy makes
# thermal_core start with plat_vtskin_info NULL, which hangs mbrain during
# cold boot and bootloops the device via hang_detect. (The v1.4 brick.)
if [ -f /data/vendor/thermal/thermal.conf ]; then
  head -c 6 /data/vendor/thermal/thermal.conf 2>/dev/null | grep -q "qqomh" \
    && rm -f /data/vendor/thermal/thermal.conf
fi
rm -f /data/adb/honor_charge_unlock.thermal_mounted
rm -f /data/adb/honor_charge_unlock.pid

# region_bypass: the China-market identity (msc.config.optb==156) is read ONCE
# at process start by every google-management gate (PGGoogleServicePolicy in
# system_server, PowerGenie, iAware). Flipping it here runs before zygote, so
# those processes latch the overseas value and the whole national-rom google
# control stack never arms. Non-persistent: a reboot without the flag returns
# the stock region (prop is re-set by cust at every boot).
if [ "$region_bypass" = "1" ]; then
  # -n writes the property area directly (bypasses init's sepolicy check,
  # which denies ksu-domain set_prop on the msc.config label; verified live)
  if command -v resetprop >/dev/null 2>&1; then
    resetprop -n msc.config.optb 392
  fi
fi

# qr_fix (v1.9.8): camera QR-scan fix. The ROM has no dedicated AF scenario
# for the QR/document capture scene (imgsensor scenario table = stock MTK list
# only; CAMERA_HW_SM_DOCUMENT_SCENE links the generic PROFESSIONAL state), and
# the rear-main 6-frame airaw pipeline runs the QRFUSION multi-frame fusion
# for it (facemaskconfig algo slot 5, CameraPosition 0). With AF hunting
# between score peaks on the high-contrast QR pattern, the 6-frame burst fuses
# frames focused at different lens positions -> ghost-blurred captures. The
# module's qrfix/facemaskconfig.xml is the stock file with the <Algo name="5">
# entry removed; bind-mounting it over the /odm original (no partition write,
# dm-verity untouched) makes camerahalserver load the plain path. Applied here
# (pre-zygote) so the HAL can never read the stock file on cold boot; the
# source label under /data/adb matches the live-verified path and the switch
# off path (service.sh / uninstall) is a plain umount.
QR_TGT=/odm/etc/camera/airaw/facemaskconfig.xml
QR_STF=/data/adb/honor_charge_unlock.qr
if [ "$qr_fix" = "1" ] && [ -f "$MODDIR/qrfix/facemaskconfig.xml" ] && [ -f "$QR_TGT" ]; then
  if grep -aq "facemaskconfig.xml" /proc/mounts 2>/dev/null; then
    echo "on" > "$QR_STF" 2>/dev/null
  elif mount --bind "$MODDIR/qrfix/facemaskconfig.xml" "$QR_TGT" 2>/dev/null; then
    echo "on" > "$QR_STF" 2>/dev/null
  else
    echo "mount-failed" > "$QR_STF" 2>/dev/null
  fi
else
  umount "$QR_TGT" 2>/dev/null
  echo "off" > "$QR_STF" 2>/dev/null
fi

# lsp_fix (v1.9.5): Honor's PackageParser NPEs inside the lspd daemon when
# parsing system-scope LSPosed modules (HnPackageUtils.notNeedCustomedPermission
# -> ActivityManager.isSystemReady -> ActivityManagerInternal is null in
# non-system_server processes), so system-scope modules get silently dropped
# from the system_server module list. The NPE is behind a CN-locale-only gate
# (isChinaVersion): masking the locale to en-US here - pre-zygote, before lspd
# parses the module list - makes the gate return false and the whole branch is
# skipped. service.sh restores zh-CN a few seconds after boot_completed, well
# after the parse window. Verified on LDY-AN00 / MagicOS 10 (ex-honor_lsp_fix
# module).
if [ "$lsp_fix" = "1" ]; then
  RP=/data/adb/ksu/bin/resetprop
  [ -x "$RP" ] || RP=resetprop
  "$RP" ro.product.locale.language en
  "$RP" ro.product.locale.region US
  echo "$(date) masked" > /data/adb/honor_charge_unlock.lsp 2>/dev/null
fi
exit 0
