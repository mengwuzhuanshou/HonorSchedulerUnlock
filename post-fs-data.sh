#!/system/bin/sh
# Honor Charge Unlock - post-fs-data stage
# Only cleans up. The charge unlock itself is done by service.sh's runtime
# daemon; nothing here can stall boot.
MODDIR=${0%/*}
. "$MODDIR/state.sh"

# Virtual A/B still owns system_a during this boot; touching it risks killing
# snapuserd and turning the merge into a bootloop. Skip the whole boot, not a
# delayed retry: the pre-zygote property/mount window cannot be replayed later.
if st_merge_pending; then
  mkdir -p "$ST" 2>/dev/null
  rm -f "$ST/pid" "$ST/thermal_mounted"
  st_merge_boot=$(st_boot_id)
  [ -n "$st_merge_boot" ] && printf '%s\n' "$st_merge_boot" > "$ST/merge_skip"
  exit 0
fi
rm -f "$ST/merge_skip"
rm -f "$ST/pid"
st_init

CONF=$ST/conf
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
[ -n "$scroll_cap" ] || scroll_cap=800000
HCU_UNIPERF_FLAG=/data/vendor/iaware/hcu_scroll_cap
rm -f "$HCU_UNIPERF_FLAG" "$HCU_UNIPERF_FLAG.tmp"
if [ "$scroll_cap" != "0" ]; then
  : > "$HCU_UNIPERF_FLAG.tmp" 2>/dev/null \
    && chown 1000:1000 "$HCU_UNIPERF_FLAG.tmp" 2>/dev/null \
    && chmod 600 "$HCU_UNIPERF_FLAG.tmp" 2>/dev/null \
    && chcon u:object_r:data_vendor_iaware:s0 "$HCU_UNIPERF_FLAG.tmp" 2>/dev/null \
    && mv -f "$HCU_UNIPERF_FLAG.tmp" "$HCU_UNIPERF_FLAG" 2>/dev/null
fi

# UniPerf touch guard overlay. This KSU build does not magic-mount module
# system directories, so bind the patched library before any vendor process can
# dlopen it. The stock partition remains untouched.
UNIPERF_TGT=/vendor/lib64/libmtk_wrapper.so
UNIPERF_SRC=$MODDIR/system/vendor/lib64/libmtk_wrapper.so
UNIPERF_ST=$ST/uniperf_filter
UNIPERF_STOCK_SHA=71f76a93c9107fc93f821e80291e8720ae67528122404a1f3783922bd67163ea
if [ "$scroll_cap" != "0" ] && [ -f "$UNIPERF_SRC" ] && [ -f "$UNIPERF_TGT" ] \
    && [ "$(sha256sum "$UNIPERF_TGT" 2>/dev/null | cut -d' ' -f1)" = "$UNIPERF_STOCK_SHA" ]; then
  chcon u:object_r:vendor_file:s0 "$UNIPERF_SRC" 2>/dev/null
  if grep -aq " $UNIPERF_TGT " /proc/mounts 2>/dev/null; then
    echo "on" > "$UNIPERF_ST" 2>/dev/null
  elif mount --bind "$UNIPERF_SRC" "$UNIPERF_TGT" 2>/dev/null; then
    echo "on" > "$UNIPERF_ST" 2>/dev/null
  else
    echo "mount-failed" > "$UNIPERF_ST" 2>/dev/null
  fi
else
  umount "$UNIPERF_TGT" 2>/dev/null
  echo "off" > "$UNIPERF_ST" 2>/dev/null
fi

# Hash-gated overlay: suppress only PowerHAL's CPU4 1.6 GHz write during touch.
POWERHAL_TGT=/vendor/lib64/libpowerhal.so
POWERHAL_SRC=$MODDIR/system/vendor/lib64/libpowerhal.so
POWERHAL_ST=$ST/powerhal_filter
POWERHAL_STOCK_SHA=914bd1a92e679920f36adf8957e792ccaec4cc8ea283b5481034d5d38d20a13c
if [ "$scroll_cap" != "0" ] && [ -f "$POWERHAL_SRC" ] && [ -f "$POWERHAL_TGT" ] \
    && [ "$(sha256sum "$POWERHAL_TGT" 2>/dev/null | cut -d' ' -f1)" = "$POWERHAL_STOCK_SHA" ]; then
  chcon u:object_r:vendor_file:s0 "$POWERHAL_SRC" 2>/dev/null
  if grep -aq " $POWERHAL_TGT " /proc/mounts 2>/dev/null; then
    echo "on" > "$POWERHAL_ST" 2>/dev/null
  elif mount --bind "$POWERHAL_SRC" "$POWERHAL_TGT" 2>/dev/null; then
    echo "on" > "$POWERHAL_ST" 2>/dev/null
  else
    echo "mount-failed" > "$POWERHAL_ST" 2>/dev/null
  fi
else
  umount "$POWERHAL_TGT" 2>/dev/null
  echo "off" > "$POWERHAL_ST" 2>/dev/null
fi

# remove a leftover thermal policy override from older versions.
# WARNING: do NOT re-add this. Delivering a vtskin-DISABLING policy makes
# thermal_core start with plat_vtskin_info NULL, which hangs mbrain during
# cold boot and bootloops the device via hang_detect. (The v1.4 brick.)
if [ -f /data/vendor/thermal/thermal.conf ]; then
  head -c 6 /data/vendor/thermal/thermal.conf 2>/dev/null | grep -q "qqomh" \
    && rm -f /data/vendor/thermal/thermal.conf
fi
rm -f $ST/thermal_mounted

# Region identity. Both region levers are pinned here because every consumer
# reads them exactly once, at process start (static final), so a later write
# would not reach code that already booted:
#   msc.config.optb == 156   China-market identity behind the whole google
#                            control stack - PGGoogleServicePolicy in
#                            system_server, the PowerGenie GMS-uid firewall, the
#                            iAware 7-day background-privilege grace and the MCS
#                            probe fuse all latch it before zygote.
#   ro.product.locale.region == "CN"  the isChinaVersion gate, read as a static
#                            final by ~15 framework classes; one of them is
#                            HwUiccControllerReference#checkCardEid, which only
#                            runs the eUICC EID-vs-oeminfo comparison (and
#                            powers down a mismatched eSIM in slot 2) on CN.
# Nothing persists: init/cust rebuild the prop area every boot, so "default" -
# or removing the module - returns the stock identity at the next reboot.
# A mode change therefore only takes effect after a reboot.
RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=resetprop
region_mode_eff=$region_mode
if [ -z "$region_mode_eff" ]; then
  # confs written before v2.2.1 carry only the old region_bypass on/off key
  if [ "$region_bypass" = "1" ]; then region_mode_eff=overseas; else region_mode_eff=default; fi
fi
case "$region_mode_eff" in
  cn)
    # -n writes the property area directly (bypasses init's sepolicy check,
    # which denies ksu-domain set_prop on the msc.config label; verified live)
    "$RP" -n msc.config.optb 156 2>/dev/null
    "$RP" ro.product.locale.language zh 2>/dev/null
    "$RP" ro.product.locale.region CN 2>/dev/null
    ;;
  overseas)
    "$RP" -n msc.config.optb 392 2>/dev/null
    "$RP" ro.product.locale.language en 2>/dev/null
    "$RP" ro.product.locale.region US 2>/dev/null
    ;;
esac

# thirdparty_home (v2.3.0): let a third-party launcher become the default home
# WITHOUT the lsp_fix locale mask. Two Honor gates guard a non-stock home here,
# and gate 2 keys off gate 1, so one lever disarms both:
#   gate 1 - PackageManagerService#hasSystemFeature("android.software.home_screen")
#     is short-circuited by HwPackageManagerServiceUtils#isUnsupportedFeatrue():
#     IS_CHINA && (ro.build.characteristics == "default" || "tablet") => false.
#     Both IS_CHINA (ro.product.locale.region == "CN") and CHARACTERISTICS are
#     static finals latched when system_server initialises that class, i.e. in
#     this pre-zygote window.
#   gate 2 - AntiMal: HwAntiMalPlugin#getAntimalProtectionPolicy() forwards to the
#     system manager's engine (AntimalServicePlugin -> ge), which answers
#     protectresult=0 ("Support home screen.") as soon as the home_screen feature
#     is true - before any cloud whitelist is consulted.
# So masking ONLY ro.build.characteristics to "phone" opens the feature bit for
# the whole boot. Every ROM consumer of that prop accepts "phone" as a phone:
# most test ("phone" || "default"); the rest test tablet/tv/watch/mobiletv, which
# "phone" does not match either. locale/region are untouched - this option is
# independent of lsp_fix and of region_mode.
# Cost - one strict "default" test exists: DataUtils.IS_PHONE gates the display-
# engine recommendation capsule receiver. tph_restore.sh puts the prop back as
# soon as the package service is published (one has-feature query first, which
# both proves the mask landed and forces the static latch); that is normally
# before DisplayEngineService is constructed (setupHwServices in
# startOtherServices), so the capsule receiver survives - but the race is not
# guaranteed, and when it is lost this boot simply has no recommendation capsule
# (the panel records the feature answer). Nothing persists: init rebuilds the
# prop area every boot.
if [ "$thirdparty_home" = "1" ]; then
  RP=/data/adb/ksu/bin/resetprop
  [ -x "$RP" ] || RP=resetprop
  tph_orig=$(getprop ro.build.characteristics)
  [ -n "$tph_orig" ] || tph_orig=default
  printf '%s\n' "$tph_orig" > $ST/tph_orig 2>/dev/null
  rm -f $ST/tph.done 2>/dev/null
  "$RP" ro.build.characteristics phone 2>/dev/null
  echo "$(date) masked->$(getprop ro.build.characteristics) (stock $tph_orig)" \
    > $ST/tph 2>/dev/null
  # start the restorer now: zygote is not up yet, so this is the only chance to
  # land the restore before system_server builds the display-engine service
  if [ -f "$MODDIR/tph_restore.sh" ]; then
    if [ -x /system/bin/setsid ]; then
      ( /system/bin/setsid sh "$MODDIR/tph_restore.sh" >/dev/null 2>&1 & ) 2>/dev/null
    else
      ( sh "$MODDIR/tph_restore.sh" >/dev/null 2>&1 & ) 2>/dev/null
    fi
  fi
else
  # stale sidecar from a boot where the switch was on: the prop area is rebuilt
  # by init every boot, so only the markers need clearing
  rm -f $ST/tph_orig $ST/tph.done 2>/dev/null
  echo "$(date) off" > $ST/tph 2>/dev/null
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
QR_STF=$ST/qr
if [ "$qr_fix" = "1" ] && [ -f "$MODDIR/qrfix/facemaskconfig.xml" ] && [ -f "$QR_TGT" ]; then
  # the source lives under /data/adb (adb_data_file) and the HAL domain cannot
  # read that label; match the stock target's label before the pre-zygote mount
  chcon u:object_r:vendor_configs_file:s0 "$MODDIR/qrfix/facemaskconfig.xml" 2>/dev/null
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

# esim_fix (v2.4.0, merged eid_guard): the eSIM EID-mismatch power-down, disarmed
# inside this module (no extra LSPosed APK for THIS half). HwUiccControllerReference#checkCardEid only
# forbids a card when BOTH EIDs are non-empty and different, so an empty oeminfo
# EID removes the whole path - no setSimPowerStateForSlot(slot, 0) and no
# OemEidMismatchDialogActivity on slot 2. Java reaches the NV only through the
# native getOeminfoEidInner(int), i.e. static NativeGetOeminfoEid at 0x1308 of
# /system/lib64/liboeminfoInf_esim.so; that symbol is not exported (JNI_OnLoad
# registers it), so the address came from the .gnu_debugdata mini symtab. The
# shipped splice turns the JNI return into a NULL jstring, which
# TextUtils.isEmpty() reads as empty.
# COST - the reason the default is off: getOeminfoEid() has a second consumer,
# HwPhoneService.getEid() -> HwEuiccControllerEx.sendEidAndActivationCodeToRil(),
# which hands the device EID plus the activation code to the modem (RIL message
# 1008). With the guard on, that EID is empty, so ADDING AN eSIM BY ACTIVATION
# CODE (domestic carriers) FAILS. Switch this off and reboot before doing that,
# then back on.
# Only the 64-bit lib is mounted: the check runs in com.android.phone (64-bit).
# Applied pre-zygote because the lib is mapped on the first SIM state change and
# an already-mapped copy is never re-read (nothing maps it at boot on this build,
# verified, which is why service.sh can still apply a later switch change live).
# Only the 64-bit lib is mounted: the check runs in com.android.phone (64-bit).
# Applied pre-zygote because the lib is mapped on the first SIM state change and
# an already-mapped copy is never re-read (nothing maps it at boot on this build,
# verified, which is why service.sh can still apply a later switch change live).
# eidfix/apply.sh holds the offset, both sha pins and the full cost note.
# v2.4.0: esim_fix replaces eid_guard. On an upgrade boot the conf may not have
# esim_fix yet (service.sh writes the migration later); fall back to the old
# eid_guard value so the cold-boot mount stays correct.
esim_fix_eff=$esim_fix
[ -z "$esim_fix_eff" ] && esim_fix_eff=$eid_guard
[ -z "$esim_fix_eff" ] && esim_fix_eff=0
sh "$MODDIR/eidfix/apply.sh" "$MODDIR" "$esim_fix_eff"


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
  echo "$(date) masked" > $ST/lsp 2>/dev/null
fi
exit 0
