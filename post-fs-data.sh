#!/system/bin/sh
# Honor Charge Unlock - post-fs-data stage
# Only cleans up. The charge unlock itself is done by service.sh's runtime
# daemon; nothing here can stall boot.
MODDIR=${0%/*}

CONF=/data/adb/honor_charge_unlock.conf
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

# remove a leftover thermal policy override from older versions.
# WARNING: do NOT re-add this. Delivering a vtskin-disabling policy makes
# thermal_core start with plat_vtskin_info NULL, which hangs mbrain during
# cold boot and bootloops the device via hang_detect.
if [ -f /data/vendor/thermal/thermal.conf ]; then
  head -c 6 /data/vendor/thermal/thermal.conf 2>/dev/null | grep -q "qqomh" \
    && rm -f /data/vendor/thermal/thermal.conf
fi
rm -f /data/adb/honor_charge_unlock.thermal_mounted
rm -f /data/adb/honor_charge_unlock.pid
exit 0
