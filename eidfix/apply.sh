#!/system/bin/sh
# eid_guard applier - shared by post-fs-data.sh (cold boot) and service.sh (panel
# toggle), so the two sha pins below can never drift apart.
#   $1 = module dir   $2 = 0|1
# Idempotent and never writes a partition: the patched lib is regenerated from
# the factory copy on every call, off = plain umount. The resulting state is
# written to the state file: on / off / unsupported / mount-failed /
# patch-failed / missing.
MODDIR=$1
EID_ON=$2
EID_TGT=/system/lib64/liboeminfoInf_esim.so
# factory lib, read back from the device and byte-identical to the copy the
# offset below was derived from. A firmware build with a different lib reports
# "unsupported" and the guard stays inert.
EID_STOCK_SHA=02fa215f5aa7971fb5c173e039056d205cab34fff3088602fdfec79f8c922048
# same file with 0x1308 spliced to `mov x0,#0; ret` (NativeGetOeminfoEid entry)
EID_OUT_SHA=faf613c59d43e8ae4e35f4d6464923cba8044b373f1dce347ceb73ab960c0d5d
. "$MODDIR/state.sh"
st_init
EID_DIR=$ST/eidfix
EID_STF=$ST/eid

# unmount first: the sha gate must read the factory lib, not a previous patch
umount "$EID_TGT" 2>/dev/null
if [ "$EID_ON" != "1" ]; then
  echo "off" > "$EID_STF" 2>/dev/null
  exit 0
fi
if [ ! -f "$EID_TGT" ] || [ ! -f "$MODDIR/eidfix/patch.bin" ]; then
  echo "missing" > "$EID_STF" 2>/dev/null
  exit 0
fi
if [ "$(sha256sum "$EID_TGT" 2>/dev/null | cut -d' ' -f1)" != "$EID_STOCK_SHA" ]; then
  echo "unsupported" > "$EID_STF" 2>/dev/null
  exit 0
fi
mkdir -p "$EID_DIR" 2>/dev/null
EID_GEN=$EID_DIR/liboeminfoInf_esim.so
cp "$EID_TGT" "$EID_GEN.new" 2>/dev/null
# 0x1308 = 4872 = 609*8, so one 8-byte block lands exactly on the function entry
if dd if="$MODDIR/eidfix/patch.bin" of="$EID_GEN.new" bs=8 seek=609 count=1 \
     conv=notrunc 2>/dev/null \
   && [ "$(sha256sum "$EID_GEN.new" 2>/dev/null | cut -d' ' -f1)" = "$EID_OUT_SHA" ]; then
  mv "$EID_GEN.new" "$EID_GEN" 2>/dev/null
  chmod 644 "$EID_GEN" 2>/dev/null
  # the stock label is system_lib_file; the radio domain cannot read
  # adb_data_file, so match it before mounting
  chcon u:object_r:system_lib_file:s0 "$EID_GEN" 2>/dev/null
  mount --bind "$EID_GEN" "$EID_TGT" 2>/dev/null
  # content check through the /system path: an unmounted target still reads the
  # factory lib, so cmp fails instead of reporting a false "on"
  if cmp -s "$EID_GEN" "$EID_TGT"; then
    echo "on" > "$EID_STF" 2>/dev/null
  else
    echo "mount-failed" > "$EID_STF" 2>/dev/null
  fi
else
  rm -f "$EID_GEN.new" 2>/dev/null
  echo "patch-failed" > "$EID_STF" 2>/dev/null
fi
