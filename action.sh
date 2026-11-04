#!/system/bin/sh
# Honor Charge Unlock - status / pause / resume / diag
MODDIR=${0%/*}
. "$MODDIR/state.sh"
st_init
LOG=$ST/log
DIAG=$ST/diag.txt
DC=/sys/class/hw_power/charger
IFACE=/sys/class/hw_power/interface
ADP=/sys/class/hw_power/adapter
PC=/sys/class/power_supply/primary_chg

case "$1" in
  pause)
    touch $ST/paused
    echo "[HCU] 已暂停, 恢复: su -c 'sh $MODDIR/action.sh resume'"
    exit 0 ;;
  resume)
    rm -f $ST/paused
    echo "[HCU] 已恢复"
    ;;
  proto)
    echo "[HCU] 提醒: 读 adaptor_test 会让内核当场重跑 SCP/FCP/PD 三协议探测(1-2s, 充电中会有扰动)"
    echo "  三协议返回 = $(cat $DC/charge_data/adaptor_test 2>/dev/null)"
    echo "  内核探测/仲裁原文:"
    dmesg 2>/dev/null | grep -E "adaptor_test_result|adapter_protocol_get_arbitration_result" | tail -6
    exit 0 ;;
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
      echo "--- 有效档位 iin_limit (生效输入电流 iin_rt_current 同列) ---"
      echo "  $(cat $IFACE/iin_limit 2>/dev/null | tr '\n' ' ')"
      echo "  iin_rt_current = $(cat $DC/charge_data/iin_rt_current 2>/dev/null) mA (解锁中被投成 max_iin；被系统压回时回到本头档位)"
      echo "--- 输入侧限流(AICR: 实测不绑定工作点，见下 iadapt) ---"
      for f in target_aicr_uA input_current_limit target_icc_uA current_max voltage_max input_voltage_limit lock_icc_and_aicr_en usb_type; do
        echo "  $f = $(cat $PC/$f 2>/dev/null | head -c 120)"
      done
      echo "  interface/vbus = $(cat $IFACE/vbus 2>/dev/null | tr '\n' ' ')"
      echo "  AICR 目标命中档位 = $(awk -v t="$(cat $PC/target_aicr_uA 2>/dev/null)" -v l="$(cat $IFACE/iin_limit 2>/dev/null | tr '\n' ' ')" 'BEGIN{
        if (t+0 <= 0 || l == "") { print "?"; exit }
        n = split(l, a, " ")
        for (i = 1; i < n; i += 2) if (a[i+1]+0 == t/1000) { print a[i]; exit }
        print "?" }' /dev/null)"
      echo "  (vbus 各通道全 0 表示没走 PPS/直充调压; 命中 dcp 档只是数值撞车。"
      echo "   2026-11-02 更正: 之前据此说「dcp 不是生效通道」是因为那时对 interface/* 的写入"
      echo "   全用裸数字、被内核解析器拒绝，从未进投票寄存器。语法为 <user> <lane> <mA>；"
      echo "   实测 thermal dcp 2000/3000/4000 能让 iin_rt_current 与 input_current_limit 跟随，"
      echo "   而 lvc/sc/hsc 写 20000 被钳回原档。target_aicr_uA 不随该票移动，是另一道闸)"
      echo "--- 直充热限流(解锁时应≈满档; 满档只是上限，工作点看下面 iadapt) ---"
      echo "  lvc=$(cat $DC/direct_charger/iin_thermal 2>/dev/null) sc=$(cat $DC/direct_charger_sc/iin_thermal 2>/dev/null) hsc(UFCS)=$(cat $DC/direct_charger_hsc/iin_thermal 2>/dev/null)"
      echo "--- 直充通道状态 ---"
      for d in direct_charger direct_charger_sc direct_charger_hsc; do
        echo "  [$d] mode=$(cat $DC/$d/chg_mode 2>/dev/null | tr '\n' ' ') succ=$(cat $DC/$d/direct_charge_succ 2>/dev/null) state=$(cat $DC/$d/*_state 2>/dev/null | tr '\n' ' ') iadapt=$(cat $DC/$d/iadapt 2>/dev/null) path_r=$(cat $DC/$d/full_path_resistance 2>/dev/null)"
      done
      echo "--- 协议位图 ---"
      echo "  $(cat $IFACE/enable_charger 2>/dev/null | tr '\n' ' ')"
      echo "--- PD/PPS 契约(v2.2.2, 插着 PD/PPS 头时才有内容) ---"
      echo "  tcpc/caps_info:"
      cat /sys/class/tcpc/type_c_port0/caps_info 2>/dev/null | sed 's/^/    /'
      for f in vbus_level pe_ready typec_role local_rp_level; do
        echo "    $f = $(cat /sys/class/tcpc/type_c_port0/$f 2>/dev/null | tr '\n' ' ')"
      done
      for f in pd_state src_power usb_state; do
        echo "    hw_typec/$f = $(cat /sys/class/hw_typec/typec/$f 2>/dev/null | tr '\n' ' ')"
      done
      for f in supports_usb_power_delivery type usb_power_delivery_revision; do
        echo "    partner/$f = $(cat /sys/class/typec/port0-partner/$f 2>/dev/null | tr '\n' ' ')"
      done
      echo "    port0/power_role = $(cat /sys/class/typec/port0/power_role 2>/dev/null | tr '\n' ' ')"
      echo "    port0/pwr_op_mode = $(cat /sys/class/typec/port0/power_operation_mode 2>/dev/null | tr '\n' ' ')"
      echo "    usbdp/usb = $(cat /sys/class/power_supply/usb/type 2>/dev/null) $(cat /sys/class/power_supply/usb/current_max 2>/dev/null) $(cat /sys/class/power_supply/usb/voltage_max 2>/dev/null)"
      echo "    primary_chg icc/aicr = $(cat /sys/class/power_supply/primary_chg/input_current_limit 2>/dev/null) / $(cat /sys/class/power_supply/primary_chg/constant_charge_current 2>/dev/null)"
      echo "  (caps_info 里 type 0 = 固定 PDO, type 3 = PPS APDO; selected_cap 是内核选中的下标)"
      echo "--- 仲裁日志(dmesg, 插头后生成) ---"
      dmesg | grep -E "adapter_prot_arbitration|protocol_info|chg_adapter|ufcs" | tail -25
      echo "--- 第三方桌面门控(thirdparty_home) ---"
      echo "  characteristics=$(getprop ro.build.characteristics) locale=$(getprop ro.product.locale.region)"
      echo "  home_screen feature=$(cmd package has-feature android.software.home_screen 2>/dev/null | tr -d '\r')"
      echo "  HOME role holders=$(cmd role get-role-holders android.app.role.HOME 2>/dev/null | tr '\n' ' ')"
      echo "  state=$(tail -n 1 $ST/tph 2>/dev/null)"
      echo "--- 温度阶梯表(DT, 供对照) ---"
      echo "  sc : $(cat /proc/device-tree/direct_charger_sc/temp_para 2>/dev/null | tr '\0' ' ')"
      echo "  hsc: $(cat /proc/device-tree/direct_charger_hsc/temp_para 2>/dev/null | tr '\0' ' ')"
    } > "$DIAG" 2>&1
    echo "[HCU] diag 已写入 $DIAG"
    cat "$DIAG"
    exit 0 ;;
esac

echo "===== Honor Charge Unlock 状态 ====="
if [ -f $ST/paused ]; then
  echo "运行状态: 已暂停"
else
  echo "运行状态: 运行中 (pid $(cat $ST/pid 2>/dev/null))"
fi
echo "电池: $(cat /sys/class/power_supply/battery/uevent 2>/dev/null | grep -oE 'POWER_SUPPLY_(STATUS|TEMP|CAPACITY)=[^ ]*' | tr '\n' ' ')"
echo "协议位图: $(cat "$IFACE/enable_charger" 2>/dev/null | tr '\n' ' ')"
echo "有效档位 iin_limit(mA): $(cat "$IFACE/iin_limit" 2>/dev/null | tr '\n' ' ')"
echo "输入侧限流: 目标AICR=$(cat "$PC/target_aicr_uA" 2>/dev/null)uA 生效icl=$(cat "$PC/input_current_limit" 2>/dev/null)uA 生效输入电流=$(cat "$DC/charge_data/iin_rt_current" 2>/dev/null)mA IC上限=$(cat "$PC/voltage_max" 2>/dev/null)uV x $(cat "$PC/current_max" 2>/dev/null)uA"
echo "直充热限流: lvc=$(cat "$DC/direct_charger/iin_thermal" 2>/dev/null) sc=$(cat "$DC/direct_charger_sc/iin_thermal" 2>/dev/null) hsc(UFCS)=$(cat "$DC/direct_charger_hsc/iin_thermal" 2>/dev/null)"
echo "(解锁生效的判据看 iin_limit 的 dcp 列是否=max_iin：实测只有 dcp 肯被抬高，"
echo " sc/hsc 恒被钳在温度档 12000/14500、lvc 4500，写多大都不变；生效值仍受头自报上限兜底)"
echo "适配器: type=$(cat "$ADP/adapter_type" 2>/dev/null) support_mode=$(cat "$ADP/support_mode" 2>/dev/null) max_volt=$(cat "$ADP/max_volt" 2>/dev/null) max_cur=$(cat "$ADP/max_cur" 2>/dev/null)"
tail -n 5 "$LOG" 2>/dev/null
