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
