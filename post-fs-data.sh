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
exit 0
