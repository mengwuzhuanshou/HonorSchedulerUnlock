#!/system/bin/sh
for p in $(pgrep -f [f]reqgov.sh); do
  printf "%s :: " $p
  tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null
  echo
 done
echo ===STAT===
for p in $(pgrep -f [f]reqgov.sh); do
  set -- $(cat /proc/$p/stat 2>/dev/null)
  echo "$p state=$3 utime=$14 stime=$15"
done
