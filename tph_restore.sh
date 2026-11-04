#!/system/bin/sh
# Restore ro.build.characteristics after system_server has latched
# HwPackageManagerServiceUtils' static IS_CHINA/CHARACTERISTICS pair.
#
# thirdparty_home masks the prop to "phone" in post-fs-data so gate 1
# (hasSystemFeature("android.software.home_screen")) stays open. The latch is
# committed by the first hasSystemFeature() call inside system_server; the prop
# itself has to be back to stock before DataUtils.IS_PHONE is read (it gates the
# display-engine capsule receiver). So: wait for the package service to publish
# (native `service check`, no JVM), issue exactly one has-feature query - that
# call both proves the mask landed and forces the class to initialise if nothing
# else did - then restore immediately.
#
# Idempotent: post-fs-data starts it as early as possible and service.sh starts
# it again as a fallback; the .tph.done marker makes the later run a no-op.
# Absolute paths because the post-fs-data environment has a minimal PATH.
. "${0%/*}/state.sh"
STF=$ST/tph
ORIGF=$ST/tph_orig
DONE=$ST/tph.done

orig=$(/system/bin/head -n 1 "$ORIGF" 2>/dev/null | /system/bin/tr -d '\r')
[ -n "$orig" ] || orig=default

if [ -f "$DONE" ] && [ "$(/system/bin/getprop ro.build.characteristics)" = "$orig" ]; then
  exit 0
fi

RP=/data/adb/ksu/bin/resetprop
[ -x "$RP" ] || RP=resetprop

# PMS publish: "Service package: found"; anything else (incl. "not found") keeps
# waiting. 0.1s ticks cost nothing (native client) and keep the window short.
i=0
while [ "$i" -lt 900 ]; do
  case "$(/system/bin/service check package 2>/dev/null)" in
    *": found"*) break ;;
  esac
  i=$((i + 1)); /system/bin/sleep 0.1
done

# one query = the proof and the latch; retry while the service is not answerable
# yet (cmd needs a working JVM in the very first boot seconds). The mask stays up
# during this window, which only helps: any system_server feature query that lands
# meanwhile latches the same "supported" answer.
n=0
feat=""
while [ "$n" -lt 20 ]; do
  feat=$(/system/bin/cmd package has-feature android.software.home_screen 2>/dev/null | /system/bin/tr -d ' \r')
  case "$feat" in true|false) break ;; esac
  feat=""
  n=$((n + 1)); /system/bin/sleep 1
done
[ -n "$feat" ] || feat=unknown

"$RP" ro.build.characteristics "$orig" 2>/dev/null
echo "$(/system/bin/date) feature=$feat chars=$(/system/bin/getprop ro.build.characteristics) stock=$orig" \
  > "$STF" 2>/dev/null
: > "$DONE" 2>/dev/null
exit 0
