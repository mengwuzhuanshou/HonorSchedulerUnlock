# Honor Scheduler Unlock (MTK) — 荣耀调度解锁模块

> ⚠️ **AI 生成声明 / AI-generated**：本模块的逆向分析、代码与文档均由 AI 生成并在实机实测；
> 请自行评估风险后使用。

纯 root 脚本模块（KernelSU / Magisk 双兼容），不依赖 Xposed。核心功能：

- **充电电流对抗**：亮屏 / 熄屏全程对抗充电热限流，输入电流顶到协议上限，电池侧 ICHG 推到
  4A（BUCK 路径硬件上限），SCP / UFCS 直充满档；
- **CPU 频率治理**：app 启动时三簇满频，滑动时大簇降频省电（默认 0.8G）；
- **FCM 推送保活**：国行 ROM 谷歌连通性探测换源，防 GMS 被断网 / 断推送；
- **VoLTE 解锁**：为缺 `ims` 接入点的运营商自动补行，国内外卡通用；
- **第三方桌面解锁**：不依赖 LSPosed/`lsp_fix` 就能把第三方桌面设为默认（开机前几秒掩住
  `ro.build.characteristics`，系统起来即还原，locale/区域身份不动）；
- **相机修复**：扫码场景禁用 QRFUSION 多帧融合；SmartAE 曝光目标可调；主摄 MTK ISP EE 锐化档位；
  前置美颜强度可调（当前仅人像模式，拍照页修复中）；超广角 0.7x 暗光长曝/ISO 增益可调。

模块 id 仍为 `honor_charge_unlock`（配置与数据路径沿用，更名不改 id 以兼容已有安装）。

## 适用范围（重要）

| | 充电解锁（电流对抗） | app 启动满频 / 滑动限频 |
|---|---|---|
| ✅ 实测可用 | 荣耀 Magic8 Pro Air（天玑 9500 / MT6379 充电 IC / MagicOS 10），全部开发与测试在此完成 | 同左 |
| 🟡 理论可适配（未实测） | 其它荣耀 MagicOS + 天玑(MTK) 机型：需存在 `/sys/class/hw_power/charger/direct_charger_*` 与 MT6379 系充电 IC | 其它 MTK perfserv 架构机型：需存在 `/proc/powerhal_cpu_ctrl/perfserv_freq` |
| ❌ 不适用 | 荣耀高通机型（充电栈不同）、非 MagicOS | 高通机型（无 MTK perfserv 栈）、无 root |

安装时若 `/sys/class/hw_power/charger/direct_charger_hsc` 不存在（`customize.sh` 会提示），
充电解锁在本机无效；CPU 部分取决于 `/proc/powerhal_cpu_ctrl/` 是否存在；FCM 解锁取决于
系统服务 `pgservice`（国行 MagicOS 均有，缺失时静默停用）。

## 充电（核心）

**亮屏限流原理**：厂商按屏幕状态/温度把输入电流上限投进内核 `power_vote` 注册表
（`<lane>:iin_limit`，投票人 `thermal,id:0`），聚合成 `M:ilim` 的 `eff = min(所有启用的投票)`，
内核再用 `eff` 给充电 IC 编程 AICR（`mt6379_charger_set_property, new aicr = …`）。
本模块用同一个 `thermal` 用户把 `dcp` lane 投到 `max_iin`：
`echo "thermal dcp 20000" > /sys/class/hw_power/interface/iin_limit`，`interface/iin_limit`
的 `dcp` 行读回就是这张票；系统会周期性写回场景值，守护进程以 0.3s 周期夺回（读回不同才写），
夺回次数计在 `fight`，面板与日志可见。

**电池侧 ICHG 默认 4 A（2026-11-05 实机生效，已并入电流对抗）**：`conf` 默认
`ichg_target=4000000`，`primary_chg/constant_charge_current` 读回 `4000000`，正好等于
`constant_charge_current_max=4A`——BUCK 路径的硬件天花板。实测（25% 电量、电池 3.97V）：
电池电流 2976→3969mA，`ibus:dcp` 1800→2527mA，输入功率 ≈15.7→22W，电池温度 34.9→37.1°C。
收益到这里封顶：PD 固定档契约是 9V×3A（27W），输入端拿不满，电池侧已撞 4A 上限；
再往上只有 SCP/UFCS 直充（电池 6~8A）。`pd_temp_guard=440` 仍在生效，≥44.0°C 自动释放；
旧 conf 里的 `ichg_target` 保持原值，想关掉这一半设 `ichg_unlock=0`。

**直充段落电流表（`dc_volt_unlock`，2026-11-06）**：PPS/SCP/UFCS 走
`direct_charger_hsc` 4:1 泵，电池侧恒流来自 `dc_para` 的 `volt_para*` 表，不经过
`primary_chg/constant_charge_current`——所以上面那 4 A 对直充不起作用（PPS 会话实测
电池侧 7.5 A 仍正常）。本机 `volt_para2`（20–35°C）在 4.4 V 档只给 7800 mA，正是
第三方 PPS 头 36–37.6 W 平台的直接原因。模块每次插电后用
`/sys/kernel/debug/power_debug/dc_hsc_write_pata_conf` 重写 `volt_para2`/`volt_para3`：
把 `vbat < dc_volt_vbat_cv` 的行的 `ichg_max` 抬到 `dc_volt_ichg`（只抬不降，CV 尾段不动）。
写入格式 `<组名> <24 个逗号分隔整数>`，即 8 组 `{vbat, ichg_max, ichg_min}`。

抬升天花板由内核九路聚合决定（`[I/direct_charge_data] get_max_chg_cur return %d, type=%d`
的 type=0…8：adapter×4、battery、cable、charge_ic、security、time、thermal，取最小正值）：
3.2 A 头 → adapter 12800、线缆 13200、电池/热 14500，所以表写 13200 时实际按 12800 执行；
换 5 A PPS 头后上限变成线缆 13200（10-29 的 PPS 会话日志样本）。

表改的是内核内存副本，要等下一次选表（温度组切换或新会话）才进 `di+0x2f0`，所以守护
进程在插电事件里写；若本次会话已完成选表，则下一次插电生效。≥44°C 后 `temp_para` 仍把
电流降到 6000/1700，这层不碰。

正式版开机不挂 debugfs（2026-11-06 实测：重启后 `/sys/kernel/debug` 为空，节点被藏起来），
所以 `dc_volt_push` 在节点不可写时会先 `mount -t debugfs none /sys/kernel/debug` 再写；
挂载失败就当这轮不写，不改其它状态。

`charger/direct_charger{,_sc,_hsc}/iin_thermal` 这一族**抬不上去**：内核按 DTB `temp_para`
钳到本档，超了打 `val is too large: 20000, tuned as default` 后节点仍读本档
（2026-11-04 采样 42 点/3s 间隔：sc/hsc/lvc 全程停在 12000/14500/4500，975 次拒绝）。
现在的守护进程不再写这一族——它在任何温度都不可能有收益，只贡献 54 行/分钟的内核报错。

**协议档位**（DTS 实测）：

| 路径 | product_max_pwr | 适配器最高电压 | 满档电流 |
|---|---|---|---|
| sc (SCP) | 66000 (66W) | 11V | 12000mA |
| hsc (UFCS) | 80000 (80W) | 21V | 14500mA |
| lvc | — | 5.5V | 4500mA |

档位是写满的：SCP 66W / UFCS 80W 双规格，UFCS 协商上报 80W。PD 3.1 物理通路在，
但 `enable_charger` 的协议位实测写不进，PD/PPS 是否置位取决于适配器；PPS 随 PD APDO 生效。
`ui_max_pwr=40W` 是 uevent/UI 字段：`ui_max_pwr`/`product_max_pwr` 只被
`dc_para_parse_dts_uevent` 解析、只被 `dc_pdt_init_uevent_cfg` 使用，没有任何限流路径
读它们（2026-11-06 反汇编闭合）。v2.3.0 的 36–37.6W 平台由 `volt_para2` 的 7800 mA 行
解释，不是 40000 档。

**温度墙三层**（安全阀，不要绕过）：

1. **系统场景限流**：屏幕状态 + 温度场景，守护进程对抗（见上）。
2. **内核 `temp_para` 阶梯**：`10–44°C→满档, 44–45°C→6000, 45–50°C→1700,
   ≥50°C→0`。电池 <44°C 时恒为满档；≥44°C 时从用户态无法绕过（需改 DTB）。
   模块采用显式大值策略（`max_iin=20000`），由内核按温度档钳位。
3. **充电小板物理温控**（NTC + IC 模拟保护）：独立于系统，模块不碰；
   MT6379 的 `constant_charge_current_max=4A` 等硬件限制保持原样。

**为什么不用 Zygisk**：荣耀充电控制链是单向的（系统 → sysfs → 内核固件），上游只写
不回读校验；这些 sysfs 节点就是所有充电策略的汇聚点，hook system_server 最终也只是
写节点。Zygisk 反而增加暴露面。模块是 `/data/adb/modules` 下的纯 sh 脚本 + root
`sh` 进程，不注入任何进程。真实存在的痕迹是充电电流统计 / 电池健康遥测（`power_log`、
`bms_event`、`bsoh`、NVM 记录），换任何实现都一样，属充大电流的物理后果。

> **绝不投递 vtskin-disable 类策略**：v1.4 曾持久化关闭 vtskin 皮肤温控，冷启动时
> `plat_vtskin_info is NULL` → mbrain 拿不到皮肤信息 → 开机链卡死 → 看门狗重启循环
> （pstore 已取证）。`thermal_conf_codec.py` 与解密配置仅留作研究。

## CPU 频率治理

`/proc/powerhal_cpu_ctrl/perfserv_freq` 写格式 `<slot 0-7> <min> <max>`，原子替换该簇
PM-QoS min/max 票对（slot 0-3→policy0、4-6→policy4、7→policy7），last-writer-wins、
无 TTL——续写方通吃。

- **launch_boost**：信号为 ActivityManager `Start proc ... for [next-]top-activity`
  （过滤后台拉起），结束于 `Displayed`（第一帧）或 `launch_boost_ms`（默认 2000，
  硬顶 5000）。动作：三簇 min=max 钉满（p0 2.7G / p4 3.5G / p7 4.21G），10–30Hz
  续写压过 perfserv 启动限频（原生 p4≤3.0G / p7≤3.5G）。
- **scroll_cap**：触摸事件计数增量触发（真实触摸；合成注入不可见），松手 400ms
  释放。动作：policy4 max 钳到 `scroll_cap`，launch boost 期间自动让位。实测阶梯
  （淘宝连续滑动，0.9G→0.5G）：jank 14.50% / **13.75%（0.8G，甜点）** / 15.91% /
  21.67% / 24.86%；0.7G 起单调劣化，p50 6→9ms 超出 120Hz 8.3ms 预算，故默认 0.8G。
  小簇钳制实测再 +5% 劣化，默认关闭。
- **开销**：全树 ≈3% 单核（小核）；fifo `read -t 0.1` 零 fork 节拍 + 5Hz 触摸轮询 +
  logcat 流；launch 窗口 30 写/s（单写 µs 级）。

## FCM 推送保活（v1.9）

国行 ROM 的 system_server 内有 `PGGoogleServicePolicy` 周期 HTTP 探测
google.com/accounts.google.com 判定“谷歌连通性”；失败会：① 静默拒绝 GMS 的
partial wakelock（熄屏后推送长连接饿死）② PowerGenie 以 UID 防火墙断 GMS 网络
③ iAware 在 7 天宽限后撤掉 GMS 后台优待。模块用 root 以 uid 1000 调用系统自有接口
`pgservice.setPgConfig(6, urls)` 把探测 URL 换成国内可达地址（默认 baidu/qq），探测
恒成功 → 三层全部不触发；另调用 `notifyGoogleKeepAlive` 给 GMS 冻结豁免、维持
`google_service_status=1` 与 iAware 宽限标记。

每 30 分钟 2 次 binder 调用 + 1 次 setprop + 1 次 settings 读（一次性 fork，毫秒级）
+ 系统探测本体 1 次 HTTP GET；无常驻进程、无新增轮询。`fcm_unlock=0` 全停；探测 URL
只存内存，卸载/关闭后重启即恢复出厂。海外机器为无害 no-op（非 460 运营商且探测成功
过一次后系统短路判“连通”）。

**已知限制：MCS 会绕过 bypassable VPN**（GMS 设计行为）。GMS 26.32 的 MCS 网络选择器
若发现 active 网络是 bypassable VPN（`VpnTransportInfo.isBypassable()==true`），会主动
解包 VPN、改用底层 WiFi/Cell 直连 `mtalk.google.com:5228`，无 GMS 内部 flag 可关。

**VPN 监控指示器（`vpn_lock`，默认关，只观察）**：开启后只在面板显示判定与建议——
`未连VPN` / `✓ GMS走隧道` / `⚠ GMS未入隧道（单应用模式，切全局）` / `⚠ 可旁路（换
非可旁路 VPN）`。**从不写入任何 VPN 配置**：真机实测对 VPN App 自启的手动隧道调用
`setAlwaysOnPackage(lockdown)` 会先剥离底层路由杀死存活会话，随后 `startAlwaysOnVpn`
拉不起手动隧道并回滚。用户自行在系统设置里配「始终开启 + 阻止不走 VPN 的连接」是
有效替代，模块不碰。

**区域身份（`region_mode`，默认 `default`，重启生效）**：v2.2.1 把原来的
`region_bypass` 开/关换成三选，`post-fs-data`（zygote 之前）一次钉住两根区域杠杆：

| 选项 | 写入 | 用途 |
|---|---|---|
| `default` 默认 | 都不写 | 跟随当前固件的出厂身份，模块不碰区域 |
| `cn` 国行 | `msc.config.optb 156` + locale `zh/CN` | 把身份钉回国行：刷了海外包、或身份被别的方法改过之后拧回来 |
| `overseas` 海外 | `msc.config.optb 392` + locale `en/US` | 让国行管控链整条不布防（等同原「海外旁路」） |

为什么必须写在 `post-fs-data`、且改完要重启：这两根杠杆的消费者全部在进程启动时用
`static final` 读一次——`ro.product.locale.region` 被 15 个框架类这样读
（`HwUiccControllerReference.IS_CHINA_REGION`、`HwPhoneService.CHINA_RELEASE_VERSION`、
`HwFullNetworkConfigInner.IS_CHIAN_VERSION` 等），`msc.config.optb` 被
PGGoogleServicePolicy / PowerGenie / iAware 这样读。系统起来之后再改，对已经启动的
进程不起作用，所以面板只报「待重启」。

- `optb == 156` 是国行谷歌管控链的布防开关（连通性探测 → GMS uid 防火墙 → iAware
  七天宽限）。钉成海外后这三层都不会布防，FCM 解锁退化为纯保险。
- `locale.region == CN` 是 `isChinaVersion` 家族门的开关，其中一条与卡直接相关：
  `UiccController#broadcastSimStateChanged` → `HwUiccControllerReference#checkCardEid`
  只在 CN 下比较 eUICC 上报的 EID 与 oeminfo 里出厂记录的 EID（`liboeminfoInf_esim.so`
  读 oeminfo 项 134）。不一致就 `setSimPowerStateForSlot(slot, 0)` 给该卡掉电，并把
  `oem_eid_mismatch_power_down=true` 塞进 `SIM_STATE_CHANGED` 广播，卡管理 App 随即弹
  「当前使用的非法 eSIM 无法与设备匹配，已将该卡禁用」。也就是说选「海外」会让这段
  校验根本不执行；实体卡不受它影响（`isEuicc()` 先返回 false）。

副作用（选「海外」时）：本质是模拟海外卡用户，COTA 国行参数包停发、**OTA 可能收不到
国行推送**、通知铃声选不了「无声」等区域化行为一起变。国内日常使用建议留在 `default`
或 `cn`。

非持久：属性区每次开机由 init/cust 重建，改回 `default` 并重启即恢复出厂身份，卸载
不需要额外清理。与 `lsp_fix` 的关系：`lsp_fix` 也借 locale 掩码，但只在开机早期的
lspd 解析窗口内，`sys.boot_completed` 后 5 秒恢复，而恢复目标现在跟随 `region_mode`
（`overseas` → en/US，其余 → zh/CN），所以「国行 + lsp_fix」仍落回国行，「海外 +
lsp_fix」不会被拉回。旧 conf 里的 `region_bypass=1` 自动读作 `overseas`，`0`/缺省读作
`default`。

**LSPosed 系统作用域修复（`lsp_fix`，默认关，重启生效）**：荣耀魔改的 `PackageParser`
解析系统作用域模块时调用 `HnPackageUtils.notNeedCustomedPermission()` →
`ActivityManager.isSystemReady()`，在 lspd daemon 进程内必然 NPE，模块被静默跳过。
NPE 位于 CN locale 专属分支（`isChinaVersion()` 读 `ro.product.locale.*`）；本开关在
`post-fs-data`（zygote 之前、lspd 解析模块列表之前）把 locale 临时改为 `en/US`，
该分支被跳过，`sys.boot_completed` 后 5 秒恢复 `zh/CN`。需要 LSPosed v2.2.0+
（Zygisk Next）；非荣耀/非 CN locale 下开着也无害；上游若内置修复可关闭。

**第三方桌面解锁（`thirdparty_home`，默认关，重启生效）**：让 Niagara 这类第三方桌面
能被设成默认桌面，**不依赖 `lsp_fix`**（那只是它的副作用，不是它的目的）。国行 MagicOS
把默认桌面锁在荣耀桌面上，两道闸都在 system_server，且第二道以第一道为条件：

1. **特性位短路**：`PackageManagerService#hasSystemFeature("android.software.home_screen")`
   在查特性表**之前**先问 `HwPackageManagerServiceUtils#isUnsupportedFeatrue()`：
   `IS_CHINA && (ro.build.characteristics == "default" || "tablet")` 就直接回 `false`
   （logcat：`<feature> android.software.home_screen is disabled in china area`）。
   `IS_CHINA`（读 `ro.product.locale.region`）和 `CHARACTERISTICS` 都是 **static final**，
   在 system_server 首次加载该类时冻结。HOME 角色可用性、以及设置页过滤第三方桌面时
   那句 `hasSystemFeature` 都吃这一位。
2. **抗恶意软件桌面检查**：`HwAntiMalPlugin#getAntimalProtectionPolicy()` 把请求转给
   系统管家的引擎（`AntimalServicePlugin` → `ge`），引擎判定顺序是：区域身份 →
   `ro.product.antimal_protection` → `hasSystemFeature("android.software.home_screen")`
   ——**为真立刻 `protectresult=0` 放行**（日志 "Support home screen."），连云控白名单
   都不查。取不到引擎结果时 `LAUNCHER` 类型默认返回 1（禁止），所以第一道闸必须先打开。

于是只需要一根杠杆：`post-fs-data` 在 zygote 之前把 `ro.build.characteristics` 临时写成
`phone`，让 system_server 把 `home_screen` 冻结成「支持」；locale / 区域身份一律不动，
与 `lsp_fix`、`region_mode` 互不影响。

还原交给独立脚本 `tph_restore.sh`：`post-fs-data` 在掩码后立刻用 `setsid` 拉起（zygote 还没
起，这是唯一能赶在 system_server 建显示引擎之前的机会），`service.sh` 再拉一次兜底，
`.tph.done` 保证幂等。脚本以 0.1s 粒度用原生 `service check package` 等 PMS 发布（不启
JVM），随后发一次 `cmd package has-feature android.software.home_screen`——这一问既是掩码
生效的证明，也强制 `HwPackageManagerServiceUtils` 完成静态冻结（若此前没人触发过），
读完立刻还原。读到 `true` 说明放行已冻结、本次开机有效；读到 `false` 说明掩码没落上。
两种情况都写进面板状态。

- 为什么写 `phone` 而不是别的值：本 ROM 里该属性的消费者都把它当「手机」——多数是
  `"phone".equals(...) || "default".equals(...)`（`HwActivityManager`、
  `HwActivityTaskManager`、`ActivityRecord`、`CrossDeviceManager`、各 wm 的 `IS_PHONE`），
  其余是 `tablet` / `tv` / `mobiletv` / `watch` 判断，`phone` 一个都不匹配，行为与
  `default` 等价。
- 代价：`DataUtils.IS_PHONE` 是全仓唯一的严格 `"default".equals(...)`，它门控显示引擎的
  推荐胶囊接收器（护眼/视频增强/SDR+/自动亮度提醒）。还原点是 PMS 发布之后，通常早于
  `DisplayEngineService` 的构造（`startOtherServices` 的 `setupHwServices`），所以一般
  无感；但这场竞争没有硬保证——若还原晚于该类初始化，本次开机少掉这些推荐胶囊，
  重启（或关掉开关再重启）即恢复。面板状态会标出是 `feature=true` 还是 `false`。
- 实测边界：属性区每次开机由 init 重建，关掉开关重启即恢复出厂身份；卸载模块时
  `uninstall.sh` 也会还原。开关切换要重启才生效（冻结值已定），和 `region_mode` 同理。
- 与 `lsp_fix` 的区别：`lsp_fix` 改 locale，会连带 eSIM EID 校验、COTA、铃声等区域化
  行为；本选项只碰设备形态位，且只在开机前几秒存在，系统起来后属性即还原。

## VoLTE 解锁（`volte_fix`，默认开）

国行 ROM 的 telephony APN 库只给 CN 运营商配了 `type=ims` 行，很多海外运营商
（实测 au/KDDI 44054）一行都没有 → IMS PDN 不建立 → MMTEL 无法注册。在 VoLTE-only
网络（日本三大运营商已停 2G/3G）上等于没有电话/短信，且 CS 域永久 `NOT_REG_SEARCHING`
反复搜网、空耗基带。排查确认门不在代码层：设置开关、运营商配置、平台总闸三条件全过，
缺的是数据层一行 `type=ims`。

守护进程按在插 SIM 的 `operator numeric` 检查 `content://telephony/carriers`，缺失才
插入（`apn=ims`，IPV4V6）；仅在 numeric 集合变化（换卡）时复查；首次实际插入后自动
切一次飞行模式重建 DataProfile（开机阶段，用户无感）。不动已有行，CN 卡零操作；
卸载不删除已插入的行（幂等数据，无害）。

## 相机修复

- **扫码糊 / 对焦拉锯（`qr_fix`，默认开）**：该 ROM 对 QR/文档场景无专用对焦设定，
  AF 评分多峰导致拉锯；主摄 6 帧 RAW 管线又对码场景启用 QRFUSION 多帧融合
  （`facemaskconfig.xml` 算法槽 5），焦平面不一致时融合对齐失败 → 重影糊。模块用
  去掉 QRFUSION 条目的 `facemaskconfig.xml` 在 `post-fs-data` 阶段 bind mount 覆盖
  `/odm/etc/camera/airaw/facemaskconfig.xml`。代价：码场景暗光多帧降噪略降。
- **过曝 / 高光（`smartae_target`，默认 185）**：主摄 SmartAE 的 AE 亮度目标出厂 200，
  且六个 variant 同值；高光恢复 HLR 出厂即关 → 高对比场景直接溢出。模块从出厂原文
  重建目标文件（只改 `<Target>`，共 3 处）并 bind mount 覆盖
  `/odm/etc/camera/smartae/back/SmartAE.xml`。取值：**200=出厂，185=默认，
  170–195=合理区间**；低于 ~170 室内/暗光人脸发灰闷；0=关闭。只做后置主摄。
- **锐化档位（`sharpen_level`，默认 2）**：v2.0.0 那版改的是 HDR+ 的 `hdrp_mc.xml`
  细节回加，实机 A/B 证明无效（这条管线不读那些列），已退役并从旧安装自动卸载。
  真正的后置主摄锐化在 MTK ISP 的 EE 阶段：`libispfeature_mtkcam.v4l2.so` 的
  `Smooth_EE` 从 `ISP_param.db` 的 `isp_ee_Param` 取 H1/H2/H3_GN 与
  MASTER_GN_POS/NEG，按 ISO 块插值后打包给 EECNR；`ISP_info.db` 里拍照默认
  （Feature 73）、LPNR、MFNR、AIISP 全部指向同一个 EE NVRAM group，所以改一处
  覆盖所有后置拍照路径。模块按档位把 H1_GN 与 MASTER_GN_POS/NEG 按 ISO 块同比
  缩放（保留各块相对强弱，H1 封顶 31），出厂库 sha256 校验通过后以 4096B 页补丁
  写入 /data/adb 副本并 bind mount——此 ROM 没有 sqlite3，所以不做 SQL UPDATE。
  取值：**0=关（出厂），1=×1.25，2=×1.5（默认，已实拍标定），3=×2.0，4=×2.5**；
  档位越高噪点/颗粒越明显，3/4 档未实拍标定。固件库 sha256 不符时完全不动。
- 前置美颜降幅（`beauty_cut`，默认 30）：按白名单整数强度曲线缩放
  `/odm/etc/camera/hwbeauty/front/hwbeauty_params.xml`，只动磨皮/瘦脸/大眼等
  效果行；0=出厂，10–50=合理区间，封顶 90。**当前只覆盖前置人像
  （cameraSceneMode=23）；拍照页自拍走 scene=0，读取的是
  `hwbeauty_params_lp.xml`，该文件尚未纳入，旋钮在拍照页不生效，修复中。**
- **超广角 0.7x 暗光太暗（`uw_exp_ms` / `uw_iso_gain`，默认 910ms / 100%）**：
  这台 ROM 的相机 App 不给超广角挂多帧夜景——0.7x「夜景模式」实拍 EXIF 与普通拍照
  完全相同（200ms / ISO4000 / SceneCaptureType=42），主摄夜景则是 7×130ms（应用日志
  总曝光 0.91s）。所以只能单帧：曝光时间与 ISO 增益二选一或组合。模块从工厂文件
  重建两份 payload 并 bind mount：
  1. AE pline 311（`calxncy_m030_UW_SN`，17 个锚点）只把最暗锚点的 eMax 从 200ms
     抬到 `uw_exp_ms`；`uw_iso_gain` 缩放全部锚点的 isoMin/isoMax。
  2. `libmtkcam_metastore.so` 里 4 处 `mov w8,#5`（target fps）按档位改成 2
     （200–499ms）或 1（500ms+），因为 3A 的曝光上限是 `1e9/fps-46ms`
     （fps5=199.954ms）。
  取值：`uw_exp_ms` 0=关（出厂 200ms）/ 150–999ms，默认 910ms；`uw_iso_gain`
  100–250%，默认 100%。**优先不偏色就保持 ISO 100%**：实测 160% 时 AE 用 ISO6400
  换掉曝光（910→700ms），亮度只到 luma 33.5，且 R/G 2.71（主摄夜景参考 1.75–2.01）；
  910ms/ISO4000 单帧实拍 0.9100015s、luma 26.0、R/G 1.58。目标亮度参考主摄夜景
  luma 42.5–43.1，但单帧 + 不同视场不可能完全等价，这是物理上限。
  两个工厂输入的 sha256 固定（DB `8e271ec3…`、SO `8e593aff…`），固件不匹配则完全
  不改。`.so` 只在 `camerahalserver` 启动时映射，改动会重启 HAL，重开相机生效；
  不改分区、不动 dm-verity，0=卸载还原。
- 相机改动全部是 bind mount：不改分区、不动 dm-verity、不影响 AVB；关开关或卸载
  即 plain umount 还原，重开相机生效。紫边（CAC 横向色差）在加密 tuning 内，
  AP 侧无明文抓手，只能靠降锐化 + 压高光间接缓解。

## eSIM EID 校验旁路（`eid_guard`，默认关）

反馈：卡 2 被禁用并弹 `com.hihonor.dsdscardmanager/.OemEidMismatchDialogActivity`
（「当前使用的非法 eSIM 无法与设备匹配，已将该卡禁用」）。链路是
`UiccController#broadcastSimStateChanged` → `HwUiccControllerReference#checkCardEid`
→ `setSimPowerStateForSlot(slot, 0)` + `SIM_STATE_CHANGED` 带
`oem_eid_mismatch_power_down` → 由 CardManager 起那个对话框。

`checkCardEid` 只在**两个 EID 都非空且不相等**时才禁用；所以让 oeminfo 侧的 EID
读数为空，整条路径就不触发。Java 只通过 native `getOeminfoEidInner(int)` 读这个
值，它就是 `/system/lib64/liboeminfoInf_esim.so` 里的静态函数
`NativeGetOeminfoEid`（0x1308；该符号不导出，由 `JNI_OnLoad` 注册，地址取自
`.gnu_debugdata` 里的 mini symtab）。模块自带 8 字节
`mov x0,#0` + `ret`，把 JNI 返回变成 NULL jstring，`TextUtils.isEmpty()` 读作空。

- **不需要额外装 LSPosed 模块**：投递方式和相机旋钮一致——出厂 lib sha256
  （`02fa215f…`）校验通过才生成 /data/adb 副本、splice、按目标原生标签
  `system_lib_file` chcon，再 bind mount 覆盖 /system 原件。不改分区、不动
  dm-verity，关开关或卸载即 plain umount。
- **代价（这就是默认关的原因）**：`getOeminfoEid()` 还有第二个消费者
  `HwPhoneService.getEid()` → `HwEuiccControllerEx.sendEidAndActivationCodeToRil()`，
  它把机器 EID 连同激活码作为 RIL 1008 送给调制解调器。开启状态下 EID 为空，
  **给国内运营商的合法 eSIM 输激活码/扫码添加会失败**：先关闭本选项并重启，
  添加成功后再打开。实体 SIM（插卡）不走这条流程，不受影响。
- 生效时机：该 lib 到第一次 SIM 状态变化才被映射（本 ROM 开机时无人映射，实测），
  所以面板开关重载守护即生效；若本次开机已经弹过那个框，需要重启。
- 只挂 64 位 lib：这段校验跑在 `com.android.phone`（64 位）。
- `region_mode=海外` 是零补丁的替代路径（`IS_CHINA_REGION` 是 static final 的
  locale 门，第一道门就返回 false），代价是整个国行身份变海外。
- 固件升级后出厂 sha 不匹配 → 状态 `unsupported`，完全不动该 lib。

## 安装

- KernelSU：管理器刷入 zip，或 `ksud module install honor_charge_unlock-<version>.zip`
- Magisk：管理器刷入 zip
- 重启后生效（`service.sh` 在开机完成后自启守护进程）

## 配置 `/data/adb/honor_charge_unlock/conf`

```ini
screen_on_unlock=1        # 亮屏时解除限流（核心功能）
unlock_when_screen_off=1  # 熄屏也强制解锁（默认开；会绕过真实温控，介意设 0）
poll_interval=0.3         # 轮询秒数；档位被系统写回后在一个周期内重新争取（读回不同才写）
temp_guard=0              # 电池温度 ≥ 该值（0.1°C）时暂停解锁并交还档位；0=关闭保护
max_iin=20000             # 每条 lane 投的 mA；内核按各 lane 自己的上限钳位，头的能力再兜底
iface_lanes="dcp"         # 在 interface/iin_limit 上重新投票的 lane；实测只有 dcp 接受抬档
dc_volt_unlock=1          # 直充（PPS/SCP/UFCS）电池侧恒流表抬升；0=关
dc_volt_ichg=13200        # 抬到的 ichg_max（mA）；实际仍被 adapter×4/线缆/热的最小值钳位
dc_volt_groups=volt_para2,volt_para3  # 改写的温度组（20-35°C、35-45°C），逗号分隔
dc_volt_vbat_cv=4500      # ≥该 vbat 的行是 CV 收尾，不抬
protocol_poke=1           # 开机/插电时尝试写 pd/hvc/hsc 使能节点（本机实测为只读视图）
launch_boost=1            # app 启动时三簇满频
launch_boost_ms=2000      # 满频保持上限（硬顶 5000）
scroll_cap=800000         # 滑动时大簇上限 kHz（800000=0.8G，0=关）
disable_preload=1         # 禁用预加载
fcm_unlock=1              # FCM 推送保活（探测换源+冻结豁免+宽限保持）
fcm_interval=1800         # FCM 重申间隔（秒）
fcm_probe_urls=http://www.baidu.com,http://www.qq.com  # 需国内可达且返回 200
fcm_keepalive=1           # GMS 冻结豁免（notifyGoogleKeepAlive）
fcm_grace_keeper=1        # iAware 宽限标记保持
fcm_gms_on=1              # google_service_status 保持为 1
region_mode=default       # 区域身份：default=不改写 / cn=钉 156+zh-CN / overseas=钉 392+en-US（副作用见正文）
vpn_lock=0                # GMS推送·VPN监控指示器（只观察，不写 VPN 配置）
lsp_fix=0                 # LSPosed 系统作用域修复（需 v2.2.0+，重启生效）
thirdparty_home=0         # 第三方桌面解锁（不依赖 lsp_fix，重启生效；副作用见正文）
volte_fix=1               # 为在插 SIM 补 type=ims 接入点（国内外卡通用）
volte_radio_cycle=1       # 首次插入 ims 行后切一次飞行模式重建数据配置
qr_fix=1                  # 扫码场景禁用主摄 QRFUSION 6 帧融合
eid_guard=0               # 卡2 eSIM EID 校验旁路（开=合法 eSIM 激活码添加会失败，需先关并重启）
smartae_target=185        # 主摄 SmartAE 目标（出厂 200，推荐 170-195，0=关）
sharpen_level=2           # 主摄 EE 锐化档位（0=关/出厂，1=×1.25，2=×1.5，3=×2.0，4=×2.5）
beauty_cut=30             # 前置人像磨皮/美型降幅%（出厂 0，推荐 10-50；拍照页自拍尚未覆盖，修复中）
uw_exp_ms=910             # 超广 0.7x 暗光曝光上限 ms（出厂 200，0=关，150-999）
uw_iso_gain=100           # 超广 AE 表 ISO 增益%（出厂 100，100-250；≥150 实测偏红）
verbose=0                 # 1=写日志 /data/adb/honor_charge_unlock/log
```

改完配置重启或手动重启守护进程生效。

## 手动操作

```sh
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh'          # 状态驾驶舱
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh diag'     # 全量诊断+仲裁日志
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh pause'    # 暂停
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh resume'   # 恢复
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh proto'    # 主动重跑 SCP/FCP/PD 三协议探测
```

每次插头 8 秒后会自动把协议仲裁日志（adapter_type / support_mode / 仲裁 dmesg）
追加到日志文件；插上 PD/UFCS 头再 `action.sh diag` 可看该头被仲裁到哪个协议。

## WebUI 仪表盘

KernelSU 管理器 → 模块详情 → **WebUI**：

- 实时充电（状态/功率/电流/电压/温度/电量，canvas 曲线）、协议实况、各协议
  `iin_limit`、MT6379 参数、适配器协商结果、电池健康与循环次数；
- 输入侧限流卡（v2.3.0）：IC 的 AICR/ICC 现值与目标、`lock_icc_and_aicr_en`、
  目标 AICR 命中哪一档（`dcp`/`sc`/`hsc`）、`interface/vbus` 各通道调压读数
  （全 0 = 这次没走 PPS/直充调压）；同项在 `action.sh diag` 里也有，另附
  `tcpc/caps_info` 的 PD PDO/PPS APDO 列表与内核选中的下标；
- `action.sh proto` 主动重跑一次 SCP/FCP/PD 三协议探测并打印仲裁原文（读 `adaptor_test`
  会让内核当场重跑 1–2 秒，充电中会有扰动）。
- 底栏两页（主页 / 相机）：主页放亮屏对抗 / 熄屏也对抗 / 启动拉满 / 禁用预加载 /
  FCM 保活 / VPN 监控 / 区域身份三选（默认·国行·海外）/ LSPosed 系统作用域修复 /
  第三方桌面解锁 / VoLTE 解锁 / eSIM EID 旁路 + 滑动限频档位；相机页放扫码修复 /
  主摄测光 Target / 主摄锐化档位 / 前置美颜降幅 / 超广角长曝与 ISO 增益。
  选项说明只在本文，面板里只留控件与数值区间。
- 面板轮询分两档：每 3 秒 `quick`（全部充电节点 + conf 回显 + 相机生效值，由一个
  awk 进程一次读完，实测 0.25 秒），每 ~15 秒 `full`（再叠加信号、VPN/FCM、eSIM
  这些只在开机/换卡/换头时才变的 binder 读数）。`full` 只在主页在屏幕上时才跑，
  相机页永远 `quick`；面板切到后台时一律不采集，回到前台先补一次 `quick`；旋钮
  输入框拿到焦点期间暂停采集，点「应用」后强制刷一次回显，所以输入和应用的响应
  不被采集占住。
- 只读信号卡：显示每张卡的运营商/制式/频段/RSRP/SNR/5G 实测值；**关闭面板零开销**
  （无常驻、无轮询、无通知）。荣耀状态栏信号格按自家 `levelHw` 绘制且不提供 dBm，
  故不做状态栏改动。

## 风险与限制

- `iin_thermal` 同时是真实过热限流通道。出厂配置 `temp_guard=0`（温度软闸关闭）
  且 `unlock_when_screen_off=1`（熄屏也对抗），软件层剩下的钳位是内核 `temp_para`
  阶梯。需要保守策略时把 `temp_guard` 设为 450（45.0°C），并考虑
  `unlock_when_screen_off=0`；硬件 JEITA / 充电 IC 保护仍然有效（未动）。
- 上面那句「内核会替我们钳位」只对模块真正写的两个口成立：`interface/iin_limit`
  的 lane 上限与 `direct_charger_*/iin_thermal`（写超了打 `val is too large` 再钳回
  本档）。`interface/iin_thermal` 的槽位写法**实测不钳位**（31.9°C 下
  `thermal dcp 0#20000` 原样进投票表），所以这是一条能绕过温度阶梯的口，
  本模块刻意不碰它——将来若要碰，必须自带温度软闸，不能指望内核兜底。
- 卸载模块后系统会在下一次屏幕/温控事件自动恢复原限值。
- MCS 绕过 bypassable VPN 是 GMS 行为，模块无法修；只能换非可旁路/全局 VPN。
- `region_mode=overseas` 的副作用不止文中列出的几项（区域化行为是一个面，不是一条
  清单）；只想动谷歌管控链、不想改区域身份的用户请留在 `default` + `fcm_unlock`。
- `eid_guard=1` 让本机 eSIM EID 读数变空，**国内运营商合法 eSIM 的激活码/扫码添加
  会失败**（那条流程要把 EID 送 modem），添加前请关闭并重启；实体插卡不受影响。
- `thirdparty_home=1` 依赖系统管家（`com.hihonor.systemmanager`）的抗恶意软件引擎在
  设默认桌面那一刻能作答——它按 home_screen 特性位放行，但引擎无响应时 `LAUNCHER`
  类型默认判「禁止」，表现是设置里点第三方桌面没反应（logcat：
  `NOT ALLOWED TO add preferred activity`）。开机后立刻去设偶发失败时，过一两分钟
  等系统管家常驻进程起来再试即可；面板状态只反映特性位有没有放行，不反映引擎是否答得上。
- 第三方桌面接管后，系统仍用荣耀桌面自己的 quickstep 画最近任务（`mRecentsComponent`
  永远是 `com.hihonor.android.launcher/...RecentsActivity`），所以上滑手势/堆叠样式
  等最近任务特性与「默认桌面是谁」无关；这是 ROM 结构，不是本模块能改的。
  补丁基准是出厂 lib 的 sha256，固件不符自动停用（状态 `unsupported`）。
- PD/PPS：第三方 PD/PPS 头复采（v2.3.0，53%→83% 连续 15 分钟 1Hz）。**上一版写的
  「只跑出 20W 级」作废**——那是把 `interface/vbus` 第一行（dcp 槽 5V）当成整条读数的
  读数错误。实际线端峰值 **38.4W**（18.5V×2.075A @53%/33.7°C），53–57% 区间稳定
  **36–37.6W**（113 帧），电池侧 4.37V×7.5A≈32.5W，与 DTB `dc_volt_ratio=4` 的 4:1 泵吻合
  （ibus×4≈ibat）。调压读数落在 `vbus:hsc` 行（18.2–18.9V），但 `hsc` 只是内核的计量
  槽位，不能据此断定这次跑的协议就是 UFCS/HSC（协议位读数见下）。上一版记的
  `adapter_prot_arbitration prot = SCP, chg_type = dcp` 标签本身没错（dmesg 里仍在，但
  最近一条早于这次插头 94 分钟，属历史值），错的是由它推「所以只有 20W」——同一个
  SCP 标签下这次跑到 18.9V×2.0A。同理「`iin_limit`
  被压到 4A」也是误读：`iin_limit:hsc` 恒为 14500，
  4000 那个数来自 `adapter/max_cur`（头自己声明的上限）与 `*_resist_para` 的 500–800mΩ
  线缆档（本机 `full_path_resistance=186`，落在 0–350 档 ⇒ 14500，线缆没有限住）。
  平台之后两级下降都踩在温度上：43.8°C 时 37.6→26.8W、44.8°C 时 26→18.2W。方向与
  `temp_para`（10–44→14500 / 44–45→6000 / 45–50→1700）一致，**但台阶幅度（−29%、−31%）
  不等于阶梯比（−59%、−72%）**，所以 temp_para 只是上限钳位，工作点还叠加
  `volt_para3`（35–45°C 表：4.30V→10.0A / 4.40V→7.8A / 4.55V→5.7A）与头的能力。
  这一次温度与 SoC 同向单调上升，**两者分不开**，仍需 30–50% 低电复采才能定谁压的。
  用户态写口逐个证否（1200 帧 / 20 分钟连续采集）：`input_current_limit` 1.4→3.0A、
  `target_aicr_uA` 1→3A 各自写入并读回，ibus 全程 1.94–1.99A 不动；末段 `icl` 被内核
  自己降到 825mA，而 ibus 仍是 980mA —— 写入口与生效通道不是一条。`enable_charger`
  的 `pd`/`hvc` 位 1200 帧恒为 0，实测仍写不进；v2.2.0 时代 `do_unlock()` 写的 `iin_thermal`
  被钳回 sc=12000/hsc=14500，是当时实际电流（1.0–2.0A）的 6–14 倍，**根本没绑定**。
  **上面这段的「用户态没有能抬高工作点的写口」已于 2026-11-02 作废**，原因是当时所有
  针对 `interface/*` 的写入都用裸数字，被内核解析器整条拒绝
  （`[E/power_if] unable to parse input:20000`）——即那些实验从未进入投票寄存器，
  「写了没反应」并不等于「这条通道不可写」。语法按节点分三种，`interface/` 那两个**都不接受裸数字**：
  `iin_limit`/`ichg_limit` 收 `<user> <lane> <mA>`（`thermal dcp 20000`），
  `iin_thermal`/`iin_thermal_all` 还必须带槽位 `<user> <lane> <idx>#<mA>`
  （`thermal dcp 0#20000`，`_all` 一条写多 lane）；只有第三条家族
  `charger/direct_charger{,_sc,_hsc}/iin_thermal` 收裸数字，且写超了打
  `val is too large … tuned as default` 再钳回本档。少写 `0#` 时内核**收下但整条丢弃**：
  返回码 0、没有 `parsed index` 日志、槽值不动——也就是说把 `iin_limit` 那套语法照搬到
  `iin_thermal` 同样无效（改 `do_unlock` 时最容易再踩一次）；v2.2.0 在该家族上发的裸数字
  则是当场被 `unable to parse` 拒绝。两种失败都没有任何回读，看起来都叫「写了没反应」，
  而这正是社区看到的「PPS 头完全没有对抗」。厂商自己的 `/vendor/bin/bms_thermal`
  就是这么写的，它的档位表**有两份明文副本**：`/odm/etc/power/bms_thermal.json`（3,205 B，
  sensor `ap_ntc`，10 个温度档：23–29 … 43–46、48–99°C，46–48 是空档）与
  `/vendor/etc/power/bms_thermal.json`（2,244 B，sensor `system_h`，
  只有 5 档且全从 37°C 起）—— 两份内容不同。键名直接把 lane 说明白了：
  `wcurrent_5v`→`dcp 0#`（有线 5V）、`wcurrent_9v`→`dcp 1#`（有线 9V）、
  `wlcurrent_5v`→`dcp 2#`、`wlcurrent_9v`→`dcp 3#`（这两是**无线** 5V/9V，不是更高的有线电压档）、
  `direct_charger`→`lvc `、`direct_charger_sc`/`_duo_sc`→`sc 0#`/`1#`、`_hsc`/`_duo_hsc`→`hsc 0#`/`1#`、
  `wlcurrent_sc`→`wl_sc 0#`。**tag→槽位号的权威表不在这两份 JSON 里，而是硬编码在厂商 APK 里**
  （`/system/app/HAware/HAware.apk`，包名 `com.hihonor.powergenie`，映射在 `com.hihonor.thermal.core`
  那个策略类里逐条 `put`，jadx 反出的方法名是 `t0()`）：
  除了上面这些，还多出 `wlcurrent_nofan_9v/5v`→`dcp 4#`/`5#`、`wlcurrent_hsc`/`_duo_hsc`→`wl_hsc 0#`/`1#`、
  `wlcurrent_nofan_sc`/`_duo_sc`→`wl_nofan_sc 0#`/`1#`、`wcurrent_aux_5v/9v`→`dcp_aux 0#`/`1#`、
  `bsp_current{,_sc,_buck}`→`dcp_sc 0#`/`1#`/`2#`、`wlcurrent_ctrl`→`wl `，
  写值时拼成 `"thermal " + 槽位 + "<idx>#<mA>"` —— 内核日志里那些超出两份 JSON 槽位的槽（`dcp 4#`/`5#`）
  就是这么来的。`/odm` 那份 31–33°C 档给 PPS 这类头的正是 5V 2000mA / 9V 1600mA
  （≈10–14W），与社区「PPS 只有 20W」的量级吻合。逐 lane 实测（满电、DCP 头）：
  `thermal dcp 2000/3000/4000` 使 `charge_data/iin_rt_current` 与 `interface/iin_limit`
  的 dcp 行同步跟随，`primary_chg/input_current_limit` 1000000→2000000；而 lvc/sc/hsc
  写 20000 一律被钳回 4500/12000/14500 —— **只有 dcp 这条 lane 肯被抬高**，所以
  `iface_lanes` 默认只投 dcp。`/vendor/bin/bms_thermal` 本身是 `disabled oneshot`（开机 `late-fs`
  投一次，之后仅由 `sys.bms_limit_mode=hota|normal` 翻转拉起），`pgrep -x bms_thermal` 现在是空的；
  真正持续重投的是 **`com.hihonor.iaware`（uid system）进程里的 `thermal-core-th` 线程**——kmsg 那侧的
  `caller=T4909` 就是它（`/proc/4909/cmdline` = `com.hihonor.iaware`、cgroup `pid_3677`）。
  **但那段代码不是 iAware 自己的**：线程名字符串 `thermal-core-thread` 全机只出现在
  `HAware.apk`（`com.hihonor.powergenie`）里，而 `/proc/3677/maps` 同时映着 `HAware.apk` 和它的
  `oat/arm/HAware.vdex` ⇒ powergenie 被 iAware **同进程加载**，所以 `pidof com.hihonor.powergenie` 恒空；
  `HnIAware.apk` 的 dex 里 `iin_thermal`/`wl_hsc`/`ap_ntc` 一个都没有。这也解释了为什么 23:24:20 那批
  槽位与数值（`dcp 2#1500`/`3#1400`/`wl_sc 2500`/`wl_hsc 1200`）对不上上面任何一份 JSON：
  **powergenie 读的表是它自己 APK 里的 `assets/thermal_config.xml`，而那份是 AES-CBC 密文**
  （解密入口是框架的 `android.rms.iaware.IAwareDecrypt`，密钥还要过一个 native 库才能算出来）。
  三个可以放明文覆盖件的路径 —— `/odm/etc/thermal/thermal_para_cfg.xml`、
  `/data/cota/para/thermal_config/thermal_config_cloud.xml`、`xml/thermal_config_cust.xml` ——
  **本机都不存在**。所以对社区有用的结论不变：**厂商下一票的具体数值本模块读不到、也不去猜**，
  只在它压过我们时按已知的 lane 语法重投自己的票。
  两张表里 `delay`/`schedule_time` 都写着 10，但拔头后那 9 min 只出现**一次**全表刷新
  （23:24:20 一批 15 行、同一时间戳）⇒ 不是 10 s 无脑重投，更像档位变化时才刷。
  要点只有一个：`thermal` 那一路**不需要插拔事件也会重投**，对本机不能按"事件式"设计（见下面第 3 条）；
  而 `iin_limit` 的 lane 那一路确实只在插拔/模式翻转时动。
  do_unlock 仍按「读回不等于 max_iin 才写」：实测 kmsg 从 ~20 行/秒
  降到 ~1 行/秒，而把 lane 手工压回 1000 后 daemon 在 2 秒内重新夺回。
  **投票进表 ≠ 生效**（2026-11-02 满电、拔头、31.9°C 单写实验，一次写一次采样）：
  带槽位的写法不受 `temp_para` 钳位——`thermal dcp 0#20000` 直接落进投票表，而
  `charge_data/chargelog` 第 3 列（`iin_th`）逐帧跟着走 2300→6000→20000；user 换成
  `default` 同样进表（`default dcp 0#9000` → 镜像 9000）。这条镜像是唯一的观测点：
  `interface/iin_thermal` 读回是空串、`iin_thermal_all` 是 `--w--w----` 只写节点，
  之前记的「节点本身 `cat` 返 EIO」不成立，是根本没有 show 回调/读权限。
  但每次写入内核都会打出仲裁结果：

  ```
  [I/power_if]  parsed index: 0, value: 20000
  [I/power_vote] M:ilim voter:na:thermal,id:2,en:on,val:20000,eff:na:runtest,id:5,val:1000->1000
  mt6379_charger_set_property, psp:38, val = 1000000
  ```

  即机器名 `ilim` 下 `thermal` 只是 id:2 的投票者，被选中的 `eff` 是 id:5 的 `runtest`
  （1000mA），充电 IC 按 `eff` 写（`psp:38` = 1.0A），我们的 20000 一票对线端电流
  零影响。这套仲裁在真·PPS 会话里已经定全（v2.3.0 实装后 2026-11-02 22:39 插头，17%、32.3°C）：
  每个 lane 有自己的机器 `<lane>:iin_limit`，**它的结果作为 `runtest,id:5` 这一票灌进聚合机
  `ilim`**，`ilim` 取 min 选出 `eff` 才写 IC——所以拔头那次看到的 `eff:runtest=1000` 不是哪个
  测试节点，而是 `dcp` lane 当时的输出。守护进程写入的那一帧：

  ```
  [I/power_if]   sysfs_set=iin_limit user=thermal type=dcp value=20000
  [I/power_vote] dcp:iin_limit voter:na:thermal,id:0,en:on,val:20000,eff:na:thermal,id:0,val:20000->20000
  [I/power_vote] M:ilim voter:na:runtest,id:5,en:on,val:20000,eff:na:default,id:3,val:1000->1400
  ```

  lane 机器里我们那票就是 `eff`，聚合机因此从 1000 抬到 `default,id:3` 的 1400。因果不是推的——
  IC 那侧的日志带 caller pid：
  `caller=T12418 … mt6379_charger_set_property, new aicr = 1400000, old aicr = 1000000`
  （12418 就是守护进程），47 s 后 `caller=T4909 … new aicr = 1200000, old aicr = 1400000`
  （T4909 = iAware 进程里跑的 powergenie 线程 `thermal-core-th`）。整场的 `new aicr` 轨迹只有 0 → 1000000（插头落定）→
  1400000（我们）→ 1200000（厂商）。同一帧的 sysfs 侧：`primary_chg/input_current_limit`
  1000000→1400000、`charge_data/iin_rt_current` 1000→20000，
  电池侧 `cur` 6527→9623mA、`vbus` 17428→18550mV 并稳住约 2 min（17% 电量）——
  **投票链路通了：「PPS 头完全没有对抗」到此推翻，语法写对就抬得动上限**（这条上限的含义见下面那段）。
  但只维持 47 s：厂商 powergenie 的 `thermal-core-th` 线程（T4909，跑在 iAware 进程里）按自己的温度阶梯**直接重投
  聚合票** `thermal,id:2`——13:41:55 val=2000、13:42:30 val=1400（`eff` 翻回 thermal）、
  13:43:10 val=1200 → IC `psp:38` = 1200000；1 Hz 镜像同帧跟出 `iin_th`
  2300→2000→1400→1200、`input_current_limit` 1400000→1200000，电池 `cur` 随后 9.6A→5.7A，
  这期间 `chargelog` 的 `temp` 列 323→487（32.3→48.7°C，正是抬流换来的热），阶梯自己往下压。
  尾巴（到 23:02）还把 `default,id:3` 也钉住了：它后来自己投到 **2000**
  （`M:ilim voter:na:default,id:3,en:on,val:2000,eff:na:thermal,id:2,val:1200->1200`），
  而 `eff` 一直是厂商那票 1200。⇒ **唯一还压着输入上限的就是厂商 `thermal,id:2` 聚合票**，
  `default` 与我们的 lane 票都已不是短板；要动它只能写 `interface/iin_thermal` 的带槽位口，
  而那口就是厂商温度阶梯本体（本节开头那条安全边界：实测不钳位，模块刻意不碰）。
  **但别把这场读成"多充了 40% 的电"**：抬起来的是编程进 IC 的上限，不是量到的线端电流，
  两个时刻的功率还互不自洽——22:41:30 电池侧 4.255V×9.589A≈40.8W，而同帧上限只有
  1.4A@18.6V≈26W（超出上限，说明那一刻上限并未咬住）；23:02:48 电池侧 4.342V×5.211A≈22.6W，
  与 1.2A@18.3V≈22W 对得上。整场 16%→65% 用了 21 min（平均约 32W 进电池），
  线端既没有 `ibus` 读数，`iadapt` 也读 0，所以**"抬上限有没有变成更多输入功率"这场没定**，
  要定得靠外接 USB 电流表，或等厂商那票让位。
  这场被内核接受的写一共 **2 次**（`fight` 只数第 1 次）：23:14:17 `STOP_SINK, plug out` →
  **3 s 后 `do_release` 把快照写回**，整条链干净可查：
  `caller=T12418 … sysfs_set=iin_limit user=thermal type=dcp value=1000` →
  `dcp:iin_limit … eff:na:thermal,id:0,val:1000->1000` →
  `M:ilim voter:na:runtest,id:5,en:on,val:1000,eff:na:runtest,id:5,val:1200->1000` →
  `new aicr = 1000000, old aicr = 1200000`。
  ⇒ **v2.3.0 新加的"快照交还"路径在真 PPS 头上验证通过**（当年那条"写 0 交还＝只解一半"的坑没再犯），
  同时也第三次坐实 min 模型：厂商那票还挂在 1200，`eff` 立刻换回我们的 1000。
  冷却侧顺带一格（归档尾巴里 23:24:20，拔头 10 min、无头）：NTC 44.8→36.9°C，1 Hz 镜像那列
  （`chargelog` 第 3 列）先从 1200 回到 1400，powergenie 的
  `thermal-core-th` 一次刷完整张 `iin_thermal` 表（`dcp 0#2000/1#2000/2#1500/3#1400`、
  `sc`/`hsc` 各 5000、`wl_sc 2500`、`wl_hsc 1200`）并把聚合票抬回 **2000**，而 `eff` 仍是
  `runtest,id:5,val:1000->1000` ⇒ 交还之后**压着输入上限的换成我们自己的快照**（此前是厂商的 1200）。
  那段一条 `new aicr` 都没有 —— 头已拔，IC 没重编程，所以这一格只证到票面，不证明工作点。
  顺带一句别过度解读：那批槽值并不能被上面两份 JSON 里任何一份完整解释（按 36.9°C 取 `/odm` 第 5 行，
  `dcp 0#`=2000 与四个 sc/hsc=5000 对得上，`dcp 1#` 该是 1600 却是 2000，`2#1500`/`3#1400`/`wl_sc 2500`
  两份都没有；厂商还投过 `dcp 4#`/`5#` 而两份表都只到 `3#`）—— 原因是 powergenie 用的是自己 APK 里
  那张密的 `thermal_config.xml`（见上面"三族写口"那条），**两份明文 JSON 是给 `bms_thermal` 那个
  开机跑一次就退的二进制用的**，不是持续投票者读的表。⇒ 表**在哪**已经闭合，**里面的数值**读不到
  （要拆 native 钥），所以本模块不猜"下一票是多少"，只按当前 `eff` 做事后判断。
  同一份流式件里把 `ilim` 的**投票者名册**凑齐了（插头那 1 s 全暴露）：
  `pd,id:0`（PD 源使能时投 2000）、`usb,id:1`（START_SINK 时投 0，`eff` 直接跟到 0，
  `new aicr = 0, old aicr = 1000000`）、
  `thermal,id:2`（厂商温度阶梯）、`default,id:3`、`wireless,id:4`（拔无线时 `en:off,val:-1`）、
  `runtest,id:5`（= lane 机器输出）。**禁用/无值的票打 `en:off,val:-1` 且不参与 min**，
  整场 `thermal,id:2` 出现过 2300/2200/2000/1400/1200 五档、`default,id:3` 出现过 500/1400/2000。
  另有一台并行机器 `M:ichg`（电池侧电流，`default,id:1` 投 500
  → `psp:29` = 500000），与本线的 `ilim` 各写各的寄存器。**以后判 AICR 一律 grep
  `new aicr = `**，它比 `psp:38` 直读且自带 old→new 与 caller，比数 sysfs 轮询可靠。
  `runtest` 那组节点顺带核掉：`interface/rt_test_result` 与 `rt_test_time` 读回都是
  `lvc 0 sc 0 mainsc 0 auxsc 0 hsc 0`、`rtb_success` 是 `--w`（root 也读不了），会话里也全 0，
  与上面那条 lane→聚合的灌入路径无关。同批未碰过的节点还有 `thermal_disable`（root 可读写、读为空）、
  `enable_ibat_limit`（读为空）、`power_limit`（`wl_sc 1000000000`），以及
  `/proc/scp_hw_voter`、`/proc/vcp_hw_voter` 两个投票转储入口。
  投票机制本体在 `power_common_mtk`（符号 `g_power_vote_list`、`power_vote_set`、
  `power_vote_object_para_show`，`/proc/kallsyms` 可读但地址一律被抹成 0），而文件系统里
  找不到这个 .ko（`/vendor/lib/modules` 只有 18 个不相干模块，`/vendor_dlkm`、`/odm`
  全搜为空）⇒ 静态定论只能走本地固件镜像，不能靠设备侧反汇编。
  还有一条会改变策略的观测：厂商**不需要插拔事件**就重投 `thermal` 的聚合票——满电拔头静置期间
  `iin_th` 自己从 2300 变成 2000，真会话里 47 s 内连投 2000→1400→1200。所以「对手只在插拔/模式
  翻转时事件式重投」这句只对 `iin_limit` 的 lane 行成立（本会话整场只写进 1 次、`dcp` 行一直是
  我们投的 20000），对 `iin_thermal` 那一路是**常开**。槽位空间也比先前记的大：厂商投过
  `dcp 2#1000`、`dcp 4#500`、`dcp 5#700`，还有 `wl_nofan_sc 0#500`、`wl_sc 0#2500/1#2500`、
  `wl_hsc 1#1200` 这些 lane。冷却那次厂商一次就把 dcp 四个槽刷成 0#2000/1#2000/2#1500/3#1400：
  电流随槽号下降，与上面那份 JSON「槽 = 电压档（5V/9V/12V/15V…）、同一行同时给全」的读法一致，
  所以这条映射不动，但 dcp 的槽远不止 0#/1#。两路票**互不干涉**：lane 行 20000 与
  `iin_th` 1200 同时成立，观测点各一个。`target_aicr_uA` 全程 1000000 不动是因为它不是执行值，
  跟住 `eff` 的是 `primary_chg/input_current_limit`（它是**编程进 IC 的上限**；面板那格「命中档位」
  拿 `target_aicr_uA` 与 `iin_limit` 做算术匹配，读的是不跟 `eff` 的那个值）。协商侧顺带一条：`update_pps_protocol_watt`
  把 `max_watt_in_mw` 打成 `68250000`（厂商单位 bug，应为 68250 mW），而头本身给到
  PPS 5.5–21V/3.25A，`adapter_protocol_get_arbitration_result` 却每 10 s 把结果报成
  `prot = SCP, chg_type = dcp`。
  读数分两档，别再混：**上限**看 `primary_chg/input_current_limit`（= `eff` 选出来写进 IC 的那一路，
  本会话 1000000→1400000→1200000 逐步跟）；**实际工作点**这台机器上没有直接读数——
  `chargelog` 的 `ibus` 列在 17V 直充阶段是 0，只剩只读的 `direct_charger_hsc/iadapt`
  （与 ibus 同步，早前那场 15 min 采集里 1350→950）和电池侧 `cur`/`vbus` 两个代理量。
  ⇒ 协议协商侧的天花板（`adapter/max_volt=21000`、`init_adapter_vset=17800`）本就到位
  （`ui_max_pwr=40000` 只是 uevent/UI 字段，见上）；输入电流这一道也已确认「写对语法的 lane 票能把 IC 的输入上限
  抬一档」（真 PPS 会话 1.0→1.4A，电池侧 `cur` 同帧 6.5→9.6A），抬不满是因为聚合机 `ilim` 的 min
  后面还压着厂商按温度连投的 `thermal` 聚合票（本场 47 s 内 2000→1400→1200，`default,id:3`
  后来自己抬到 2000 之后短板就只剩它）；再往外才是充电器 IC
  自己的 AICR/ICC 环路。`interface/ichg_*` 仍**不要**盲写：裸读为空、
  语法虽与 `iin_*` 同（`sysfs_set=ichg_limit user=thermal type=dcp value=0`）但它是
  电池侧电流，且无可观测回读点。
- 温度阶梯其实有**三层表**：①`charger/direct_charger*/iin_thermal` 那一路钳位来自 DTB（`temp_para` /
  `volt_para3`，改它要重编引导镜像）；②带槽位那一路的**开机/模式翻转初值**来自用户态两份明文
  `bms_thermal.json`（见上面"三族写口"那条，读它的是 `disabled oneshot` 的 `/vendor/bin/bms_thermal`）；
  ③**会话中持续重投**的那一路读的是 powergenie 自己 APK 里的 `assets/thermal_config.xml`（AES-CBC 密文，
  本机没有明文覆盖件）。三层的**执行者都不是内核自动钳位**，而是 powergenie 的 `thermal-core-th`
  线程（跑在 `com.hihonor.iaware` 进程里）按表重投 `thermal` 聚合票（实测 47 s 内 2000→1400→1200）。
  所以用户态写同一个槽能盖过它——`interface/iin_thermal` 实测不受 `temp_para` 钳位，
  这等于直接拆过热保护，模块刻意不写；`temp_guard` 是本模块唯一的软件兜底，出厂为 0。
- `uw_exp_ms` / `uw_iso_gain` 改的是相机 3A 的 AE pline 与 metastore 的 target fps。
  v2.0.6 的 `uw_gain` 曾因盲改 AE 表触发 P1Node TimeBomb；本版只改最暗锚点 eMax 与
  iso 列，并用工厂 sha256 锁定输入，910ms / ×1.6 实拍未复现崩溃。但 AE 表属 HAL 内部
  数据结构，固件升级后 sha 不匹配会自动停用；若出现相机 HAL 崩溃，先把 `uw_exp_ms=0`
  再重开相机。
- 仅 MTK / MagicOS 架构；高通机型不适用。

## 更新检测

`module.prop` 带 `updateJson`（jsdelivr CDN 的 `update.json`），KernelSU 管理器周期
比对 `versionCode` 并提示更新。发新版：bump `version`/`versionCode` → 打包 zip 到
`dist/` 并更新 `update.json`（version/versionCode/zipUrl/changelog）→ commit + push
（jsdelivr 与 raw 线路自动生效），可选建 GitHub Release 附带 zip。

## tools/

`start_hcu.sh` 分离启动/重启守护；`restart_hcu.sh` 部署+冷启动验证；
`diag_fg.sh` / `cleanup_fg.sh` / `check_fg.sh` / `restart_fg.sh` 进程树运维；
`ladder_tb.sh` 淘宝滑动阶梯复测；`legacy_freqgov/` 独立版原型存档（已合并）。

## License

MIT。详见 LICENSE。
