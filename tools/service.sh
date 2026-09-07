#!/system/bin/sh
MODDIR=${0%/*}
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 5; done
sh $MODDIR/freqgov.sh >/dev/null 2>&1 &
