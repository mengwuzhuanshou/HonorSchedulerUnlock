#!/system/bin/sh
# Honor Charge Unlock - status / pause / resume / diag
MODDIR=${0%/*}
LOG=/data/adb/honor_charge_unlock.log
DIAG=/data/adb/honor_charge_unlock_diag.txt
DC=/sys/class/hw_power/charger
IFACE=/sys/class/hw_power/interface
ADP=/sys/class/hw_power/adapter

case "$1" in
  pause)
    touch /data/adb/honor_charge_unlock.paused
    echo "[HCU] 已暂停, 恢复: su -c 'sh $MODDIR/action.sh resume'"
    exit 0 ;;
  resume)
    rm -f /data/adb/honor_charge_unlock.paused
    echo "[HCU] 已恢复"
    ;;
  diag)
    {
      echo "===== HCU diag $(date) ====="
      echo "--- battery uevent ---"
      cat /sys/class/power_supply/battery/uevent 2>/dev/null
      echo "--- usb uevent ---"
      cat /sys/class/power_supply/usb/uevent 2>/dev/null
      echo "--- adapter(协议协商结果, 接真实充电头后应非0) ---"
      for f in $ADP/*; do
        b=$(basename "$f"); [ "$b" = "uevent" ] && continue
        echo "  $b = $(cat "$f" 2>/dev/null | head -c 100)"
      done
      echo "--- 有效档位 iin_limit ---"
      echo "  $(cat $IFACE/iin_limit 2>/dev/null | tr '\n' ' ')"
      echo "--- 直充热限流(解锁时应≈满档) ---"
      echo "  lvc=$(cat $DC/direct_charger/iin_thermal 2>/dev/null) sc=$(cat $DC/direct_charger_sc/iin_thermal 2>/dev/null) hsc(UFCS)=$(cat $DC/direct_charger_hsc/iin_thermal 2>/dev/null)"
      echo "--- 直充通道状态 ---"
      for d in direct_charger direct_charger_sc direct_charger_hsc; do
        echo "  [$d] mode=$(cat $DC/$d/chg_mode 2>/dev/null | tr '\n' ' ') succ=$(cat $DC/$d/direct_charge_succ 2>/dev/null) state=$(cat $DC/$d/*_state 2>/dev/null | tr '\n' ' ')"
      done
      echo "--- 协议位图 ---"
      echo "  $(cat $IFACE/enable_charger 2>/dev/null | tr '\n' ' ')"
      echo "--- 仲裁日志(dmesg, 插头后生成) ---"
      dmesg | grep -E "adapter_prot_arbitration|protocol_info|chg_adapter|ufcs" | tail -25
      echo "--- 温度阶梯表(DT, 供对照) ---"
      echo "  sc : $(cat /proc/device-tree/direct_charger_sc/temp_para 2>/dev/null | tr '\0' ' ')"
      echo "  hsc: $(cat /proc/device-tree/direct_charger_hsc/temp_para 2>/dev/null | tr '\0' ' ')"
    } > "$DIAG" 2>&1
    echo "[HCU] diag 已写入 $DIAG"
    cat "$DIAG"
    exit 0 ;;
esac

echo "===== Honor Charge Unlock 状态 ====="
if [ -f /data/adb/honor_charge_unlock.paused ]; then
  echo "运行状态: 已暂停"
else
  echo "运行状态: 运行中 (pid $(cat /data/adb/honor_charge_unlock.pid 2>/dev/null))"
fi
echo "电池: $(cat /sys/class/power_supply/battery/uevent 2>/dev/null | grep -oE 'POWER_SUPPLY_(STATUS|TEMP|CAPACITY)=[^ ]*' | tr '\n' ' ')"
echo "协议位图: $(cat "$IFACE/enable_charger" 2>/dev/null | tr '\n' ' ')"
echo "有效档位 iin_limit(mA): $(cat "$IFACE/iin_limit" 2>/dev/null | tr '\n' ' ')"
echo "直充热限流: lvc=$(cat "$DC/direct_charger/iin_thermal" 2>/dev/null) sc=$(cat "$DC/direct_charger_sc/iin_thermal" 2>/dev/null) hsc(UFCS)=$(cat "$DC/direct_charger_hsc/iin_thermal" 2>/dev/null)"
echo "(解锁生效时 sc/hsc 应接近 12000/14500, iin_limit 同步满档; 被系统压回时约为 5000-6500)"
echo "适配器: type=$(cat "$ADP/adapter_type" 2>/dev/null) support_mode=$(cat "$ADP/support_mode" 2>/dev/null) max_volt=$(cat "$ADP/max_volt" 2>/dev/null) max_cur=$(cat "$ADP/max_cur" 2>/dev/null)"
tail -n 5 "$LOG" 2>/dev/null
