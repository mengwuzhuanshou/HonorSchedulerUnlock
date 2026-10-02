# Honor Scheduler Unlock (MTK) — 荣耀调度解锁模块

> ⚠️ **AI 生成声明 / AI-generated**: 本模块的逆向分析、代码与文档均由 AI 生成，并在下述设备上完成实测；请自行评估风险后使用。

纯 root 脚本模块（KSU / Magisk 双兼容），不依赖 Xposed。功能：**充电电流对抗**（亮屏/熄屏全程对抗充电热限流，SCP/UFCS 直充满档）+ **app 启动时 CPU 满频率** + **滑动时 CPU 降频省电**（大簇 0.8G）+ **FCM 推送保活解锁**（国行 ROM 谷歌连通性探测换源，防 GMS 被断网/断推送，v1.9）+ **VoLTE 解锁**（自动补 ims 接入点，国内外卡通用，v1.9.6）+ **相机扫码修复**（禁用主摄码场景 QRFUSION 6 帧融合，治拍二维码糊/对焦拉锯，v1.9.8）+ **相机曝光抑制 Target 可调**（主摄 SmartAE 测光目标 200→默认 185，治过曝/高光溢出，面板输入数值，重开相机生效，v1.9.9）+ **相机锐化抑制**（sharpen_cut，把主摄 HDR+ RAWNR 的细节回加与 lanczos 增强增益按百分比下调，治「锐化太重」，出厂 0 / 默认 35 / 推荐 20–50，逐模块重建后 bind mount，重开相机生效，v2.0.0）。

## 适用范围（重要）

| | 充电解锁（电流对抗） | app启动满频 / 滑动限频 |
|---|---|---|
| ✅ 实测可用 | 荣耀 Magic8 Pro Air（LDY-AN00，天玑 **9500** / MT6379 / MagicOS 10）——全部开发与测试在此设备完成 | 同左 |
| 🟡 理论可适配（未实测） | 其它荣耀 MagicOS + 天玑(MTK) 机型：需存在荣耀直充节点 `/sys/class/hw_power/charger/direct_charger_*` 与 MT6379 系充电 IC | 其它 MTK perfserv 架构机型：需存在 `/proc/powerhal_cpu_ctrl/perfserv_freq`（powerhal_cpu_ctrl.ko） |
| ❌ 不适用 | 荣耀高通(Qualcomm)机型（充电栈完全不同）、非 MagicOS | 高通机型（无 MTK perfserv 栈）、无 root |

安装时若 `/sys/class/hw_power/charger/direct_charger_hsc` 不存在（customize.sh 会提示），充电解锁功能在本机无效；CPU 部分取决于 `/proc/powerhal_cpu_ctrl/` 是否存在；FCM 解锁取决于系统服务 `pgservice`（荣耀 MagicOS 国行均有，服务缺失时功能自动静默停用）。

### FCM 推送保活解锁（v1.9）

| | 说明 |
|---|---|
| ✅ 实测 | 荣耀 Magic8 Pro Air（LDY-AN00，国行 MagicOS 10）：binder 注入成功、探测被换源触发、接口语义与逆向一致 |
| 🎯 目标场景 | 国行荣耀（`msc.config.optb=156`）+ 国内网络：GMS 已登录但推送收不到/熄屏断推 |
| 🟢 海外机器 | 无害 no-op：非 460 运营商 + 探测成功过一次后系统直接短路判"连通"，注入只是让该状态更稳 |

**原理**（完整逆向见 `docs/FCM通路逆向笔记.md`）：国行 ROM 的 system_server 内有 `PGGoogleServicePolicy`，周期 HTTP 探测 google.com/accounts.google.com 判定"谷歌连通性"；探测失败会 ①静默拒绝 GMS 的 partial wakelock（熄屏后推送长连接饿死）②PowerGenie 以 UID 防火墙直接断 GMS 网络 ③iAware 在 7 天宽限后撤掉 GMS 应用后台优待。模块用 root 以 uid 1000 调用系统自有接口 `pgservice.setPgConfig(6, urls)` 把探测 URL 换成国内可达地址（默认 baidu/qq），探测恒成功 → 三层全部不触发；另调用 `notifyGoogleKeepAlive` 给 GMS 冻结豁免、维持 `google_service_status=1` 与 iAware 宽限标记。

**耗电**：每 30 分钟 2 次 binder 调用 + 1 次 setprop + 1 次 settings 读（一次性 fork，毫秒级）+ 系统探测本体 1 次 HTTP GET。无常驻进程、无新增轮询。`fcm_unlock=0` 全停；探测 URL 列表只存内存，卸载/关闭后重启即恢复出厂。

### ⚠️ 已知限制：MCS 推送连接会绕过 bypassable VPN（GMS 设计行为，代码级确认）

GMS 26.32 的 MCS 网络选择器（`com.google.android.gms.gcm.connection`，混淆类 chyq/chyn/ciay）在挑选连接网络时（`chyq.k()`）：**若系统 active 网络是 bypassable VPN（`VpnTransportInfo.isBypassable()==true`），会主动解包 VPN、改用其底层物理网络（WiFi/Cell）直连 mtalk.google.com:5228**。此行为无 GMS 内部 flag 可关。

### 🔎 GMS推送·VPN 监控指示器（vpn_lock，v1.9.3，默认关，仅观察不改动）

针对上述问题的**观察与指引**开关。开启后，守护进程在 VPN 隧道（tun 网卡）存在时周期读取当前隧道的 `VpnTransportInfo.bypassable` 状态与 GMS 是否被路由进隧道，面板状态行给出判定与设置指引：

- `未连VPN` / `已关闭`：无活动隧道或开关未开。
- `✓ GMS走隧道`：隧道不可旁路（bypassable=false）或 GMS uid 在隧道内——MCS 无法解包，推送应正常（5228 已连时额外标注）。
- `⚠ GMS未入隧道`：VPN 是「单应用模式」且 GMS 不在隧道内 → 把 VPN 切「全局模式」。
- `⚠ 可旁路`：隧道是 bypassable VPN，GMS 可能解包直连 → 换「非可旁路/全局」VPN 才能让推送走隧道。

**为什么只观察、不下发 VPN 配置**：真机实测，对本 ROM 上由 VPN App 自启的手动隧道调用 `setAlwaysOnPackage(lockdown)` 会先剥离底层路由杀死存活的会话，随后系统 `startAlwaysOnVpn` 拉不起手动隧道并自动回滚——结果恒为「隧道死 + 锁消失」。因此本开关**从不写入任何 VPN 配置**；用户在系统设置里手动配置「始终开启 + 阻止不走 VPN 的连接」仍是有效的替代方案（那是用户自己的持久化配置，模块永不触碰）。

> 模块 id 仍为 `honor_charge_unlock`（配置/数据路径 `/data/adb/honor_charge_unlock.*` 沿用），更名不改 id 以兼容已有安装与配置。

LSPosed 当前无法注入系统组件，本模块为纯 root 脚本方案，不依赖任何 Xposed 框架。

## 实测结论（该机型侦察结果）

| 目标 | 结果 |
|---|---|
| 亮屏充电限制 | ✅ 已定位并实测可解：亮屏时荣耀充电算法把 `direct_charger_sc/hsc/iin_thermal` 压到 ~5000-6500mA（随温度浮动），熄屏放行 ~6400mA；向该节点写 `0` 后充电固件直接重算为 **12000 / 14500（满血）**。系统每 6~9 秒会把限值写回，因此模块守护进程以 2 秒周期持续重置。 |
| UFCS（hsc 路径） | ✅ 路径存在且默认已使能：UFCS 主控 `hn_mt6379_ufcs`、`enable_charger` 中 `hsc 1`、直充通道 `direct_charger_hsc`（满血 14500mA）。接 UFCS 充电器即可走 UFCS 直充。 |
| PD | ⚠️ PD 3.1 物理通路在（typec port0 报 3.1），但 `enable_charger` 位图 `pd 0`、`hvc 0`，为只读节点（内核充电固件管理，按当前适配器协议显示，多次尝试各种格式写入均被忽略）。接 PD 充电器时位图是否自动置 1 需要实测；模块保留了开机/插电时的使能尝试（poke）。 |
| PPS | ⚠️ 无独立 sysfs 开关。PPS 属于 PD APDO，由 `rt-pd-manager` 处理；只要 PD 路径放行即随之可用。无法在未接 PD/PPS 充电器的条件下进一步验证。 |
| 充电 IC 硬件限制 | 按要求不处理（MT6379 `constant_charge_current_max=4A` 等保持原样）。 |

## 亮屏限制的原理

1. `thermal_core`（荣耀热管理守护进程）+ 内核充电算法根据屏幕状态（`mWakefulness`）和温度场景，把场景限流写入荣耀电源框架节点。
2. 关键落点：`/sys/class/hw_power/charger/direct_charger_{sc,hsc}/iin_thermal`（SCP / UFCS 直充输入热限流，mA）。
3. 写 `0` → 充电固件重算为该路径的最大值（sc=12000、hsc=14500），随后系统又写回场景值 → 需要轮询对抗。

## 档位表解码（DTS 实测，回答"高瓦数档位写没写"）

`/proc/device-tree/direct_charger_*/` 关键属性解码结果：

| 路径 | product_max_pwr | 适配器最高电压 | temp_para 满档 (10–44°C) |
|---|---|---|---|
| sc (SCP) | **66000** (66W) | 11V (11000mV) | 12000mA |
| hsc (UFCS) | **80000** (80W) | 21V (21000mV) | 14500mA |
| lvc | — | 5.5V | 4500mA |

**档位是写满的**：SCP 66W / UFCS 80W 双规格，UFCS 协商上报的最大功率就是 80W（`product_max_pwr`），不存在被隐藏的更高档；`ui_max_pwr=40W` 只是界面显示口径。

## 温度墙的层次（实测）

1. **系统场景限流**（屏幕状态 + 温度场景计算出的 ~5000-7000mA）：`thermal_core`/充电算法每 **~4.4 秒**写回一次 → 守护进程 0.3s 轮询夺回，实测占空比 **≈95%**，低谷窗口 ≤0.4s（200ms 分辨率采样验证），充电固件按控制周期积分，实际影响可忽略。
2. **内核 temp_para 温度阶梯**（`10-44°C→满档, 44-45°C→6000, 45-50°C→1700, ≥50°C→0`）：位于 sysfs 之下的钳位层，任何显式写入都会被 min(写入值, 当前温度档) 封顶。**电池 <44°C 时它恒等于满档，不构成限制；≥44°C 时从用户态无法绕过**（改它需要重编 DTB 的 temp_para，属引导镜像工程）。注意写 0 会触发固件按此表重算（有 1~3s 延迟），写显式值则即时钳位生效——模块采用显式大值策略（`max_iin=20000`）。
3. **充电小板物理温控**（NTC + IC 模拟保护）：独立于系统，本模块按约定不碰。

## 检测风险分析（为什么不用 Zygisk）

- 荣耀充电控制链是**单向**的：`thermal_core`/系统充电服务 → 写 sysfs（`iin_thermal`/`iin_limit`）→ 内核充电固件执行。上游只写不回读校验，dmesg 里只有 `power_if get/set` 级别的普通日志，没有任何针对写值被覆盖的告警/比对/回滚逻辑。模块坐在最后一公里，上游对它不可见。
- 这几个 sysfs 节点**就是**荣耀所有充电策略的汇聚点——hook system_server 里的隐藏服务接口最终也只是写这些节点。Zygisk 方案（需手写 native hook，LSPosed 不可用）反而增加暴露面：zygisk 痕迹 + system_server hook 是完整性检测的重点对象，收益为零。
- 模块本体是 `/data/adb/modules` 下的纯 sh 脚本 + 一个 root `sh` 进程，不注入任何进程，App 层 root 检测（Play Integrity 等）看到的只有你已有的 KSU/tricky_store 环境。
- 真实存在的"痕迹"与模块方法无关：充电电流统计/电池健康遥测（`power_log`、`bms_event`、`bsoh`、NVM 记录）会记录长期大电流充电，售后 projectmenu 也能查充电电流史。这是目标的物理后果，换任何实现都一样。

## 档位机制（拉满的原理）

`interface/iin_limit`（`dcp/lvc/sc/hsc/wl_sc/wl_hsc` 各协议有效输入上限）是**动态推导值** = min(协议设计上限, 当前热限流)。热限流被守护进程钉到满档后，`iin_limit` 自动变为 `sc 12000 hsc 14500`（无线也跟随到 3000/2500），即充电固件自身持有的最大档（`iin_thermal_ichg_control` 值）。适配器握手后固件自动选最高支持档，不再有亮屏降档。上限即该机型设计功率（`msc.power.smart_charge_turbo=66`），超过机型设计档的部分属于硬件域，本模块按约定不处理。`ichg_control_enable`、`set_chargetype_priority` 实测无需改动（写 0 后热限流重算值就是满档值）。

### 海外区域旁路（region_bypass，v1.9.2，默认关）

`post-fs-data` 阶段 `resetprop -n msc.config.optb 392`（非持久，关掉重启即恢复国行身份）。国行身份（optb==156）被 PGGoogleServicePolicy / PowerGenie / iAware 在**进程启动时读一次**，翻转后整条国行谷歌管控链（探测、海外熔断依赖、UID 防火墙、iAware GMS 管控/宽限）全部不布防，FCM 解锁退化为纯保险。**本质是模拟海外卡用户**。副作用（系统自居海外区域所致）：COTA 国行参数包停发（对本模块是减负）、**OTA 可能收不到国行推送**（升级前关闭 + 重启）、**通知铃声选不了「无声」**等区域化行为变化——副作用不止已知这些，请自行探索。模拟海外卡/海外长期使用适用；国内使用请勿开启。

### LSPosed 系统作用域修复（lsp_fix，v1.9.5，默认关，重启生效）

**问题**：荣耀魔改的 `PackageParser` 在解析系统作用域（system）LSPosed 模块时调用 `HnPackageUtils.notNeedCustomedPermission()` → `ActivityManager.isSystemReady()`，该调用链在 `lspd` daemon 进程内必然 NPE（`ActivityManagerInternal` 为 null），解析抛 `PackageParserException`，模块被**静默跳过**——不进 system_server 的模块列表。App 作用域模块走另一条代码路径，不受影响。崩溃特征：

```
W/LSPosedService: failed to parse /data/app/.../base.apk
Caused by: java.lang.NullPointerException: ...ActivityManagerInternal.isSystemReady()
  at android.util.HnPackageUtils.notNeedCustomedPermission(HnPackageUtils.java:213)
```

**修复**：NPE 位于 CN locale 专属分支（`isChinaVersion()` 读 `ro.product.locale.*`，仅 zh/CN 才走）。本开关在 `post-fs-data` 阶段（zygote 之前、lspd 解析模块列表之前）把 locale 临时改为 `en/US`，该分支被完全跳过、解析正常返回；`sys.boot_completed` 后 5 秒自动恢复 `zh/CN`（用户无感）。零监听、零轮询（仅一次 1s 间隔的等待循环直到开机完成）。

- 需要 LSPosed v2.2.0+（Zygisk Next）。开启后**重启**才生效（mask 在 post-fs-data 阶段）。
- 非荣耀设备/非 CN locale 下该分支本来就返回 false，开关开着也无害。
- 状态文件 `/data/adb/honor_charge_unlock.lsp`（`masked <ts>` / `restored <ts>` / `off`），面板「系统状态」卡有状态行。
- 上游 LSPosed 正在迭代新版包解析器，将来可能内置修复——届时可关闭此开关。
- 机制与原独立模块 honor_lsp_fix（v1.0.1）一致，后者的安装脚本在 KSU v3.x 下有 `os error 2` 坑（`SKIPUNZIP=1` + 平铺文件布局触发安装器清理阶段的 `rmdir -p` 删空 `modules_update` 目录），v1.0.1 已改为标准 `SKIPUNZIP=0` 流 + 防御性重解包。

### VoLTE 解锁（volte_fix，v1.9.6，默认开）

**问题**：国行 ROM 的 telephony APN 数据库只给 CN 运营商配了 `type=ims` 接入点（联通行：`apn=ims, type=ims`），很多其他运营商一行都没有——海外的（实测 au/KDDI 44054）没有，国内部分被 ROM 屏蔽/漏配的卡也可能没有。没有 ims 接入点 → IMS PDN 永远不建立 → MMTEL 无法注册。在 VoLTE-only 网络（日本三大运营商均已停 2G/3G）上等于**没有电话、没有短信**，且语音域（CS）永久卡在 `NOT_REG_SEARCHING` 反复搜网——既打不了电话，也在持续空耗基带信令（待机耗电来源之一）。**与国别无关：只要在插 SIM 的运营商缺 ims 行就补，国内外卡通用。**

**排查链**（本机实测）：设置里 VoLTE 用户开关是开的（`hn_volte_user_switch_N=1`）、运营商配置 `carrier_volte_available_bool=true`、框架总闸 `HwImsManagerInner.isVolteEnabledByPlatform()`（设备配置 && 运营商配置 && GBA）三条件全过——门不在代码层，在**数据层**：补一行 `type=ims` 后框架立即用内置 `DEFAULT IMS` 档（DNN `ims`）激活 IMS 承载，网络下发 P-CSCF 地址（QCI5），与 CN 卡的 IMS 承载形态完全一致。**所以这不是"设置被屏蔽"，是配置库里缺一行数据**；框架层无任何可 hook 的必要。

**实现**：守护进程内的幂等 watcher——按在插 SIM 的运营商 `operator numeric` 检查 `content://telephony/carriers` 是否已有 `type=ims` 行，缺失才插入（`apn=ims`，IPV4V6），仅当 numeric 集合变化（换卡）时重新检查；首次实际插入后自动切一次飞行模式让数据栈重建 DataProfile（开机阶段执行，用户无感）。不动任何已有行，CN 卡永远零操作。

- 状态文件 `/data/adb/honor_charge_unlock.volte`（`wait-sim` / `ok <numeric列表> [inserted=N]` / `radio-cycle` / `err`），面板「系统状态」卡有状态行。
- `volte_radio_cycle=1`（默认）控制是否在首次插入后切飞行模式；设 0 则等用户自己重启/切飞行模式生效。
- 对 CN 卡、已有 ims 行的运营商是零操作 no-op；卸载模块不会删除已插入的行（幂等数据，无害）。

### 相机扫码修复（qr_fix，v1.9.8，默认开）

**问题**：荣耀相机拍二维码很糊、扫码要反复拉远拉近才能识别。逆向定论：① 该 ROM 对 QR/文档场景**没有任何专用对焦设定**（MTK 场景表只有标准场景），QR 高频黑白图案让 AF 评分出现多个局部极大值 → 连续对焦在峰间"打猎"（拉锯）；② 主摄 6 帧 RAW 管线（airaw）为码场景启用了 **QRFUSION 多帧融合**（`facemaskconfig.xml` 算法槽 5，仅后置主摄），对焦拉锯期间 6 帧焦平面不一致 → 融合对齐失败 → **重影糊**，比单帧更糊；③ "锐化太重"的观感是失焦图被锐化后的振铃白边，是表象不是根因。

**实现**：模块自带 `qrfix/facemaskconfig.xml`（原版去掉 `<Algo name="5">` QRFUSION 条目，其余逐字节一致），`post-fs-data` 阶段（早于一切相机进程）**bind mount** 覆盖 `/odm/etc/camera/airaw/facemaskconfig.xml`。不改分区、不动 dm-verity、无 AVB 影响；面板切换即时生效（守护重启时挂载/卸载），重开相机加载新配置。

- 关开关 = plain umount，瞬间还原官方原版行为；卸载模块同样自动 umount。
- 生效判定：`/data/adb/honor_charge_unlock.qr` = `on`（v1.9.9 起面板不再单列状态行，开关本身即状态）。
- 代价：码场景暗光多帧降噪略降（码拍照退回普通路径）；对焦拉锯本身是系统 AF 行为，拍码时点按对焦等锁定再拍效果最佳。

### 相机曝光抑制 · 主摄测光目标 Target（smartae_target，v1.9.9，默认 185）

**问题**：社区反馈「过曝」+「高光压不住」。逆向定论：① 主摄 SmartAE 的 AE 亮度目标 `<Target>` 出厂 = **200**，且六个 variant（back / back·aperture / back·tele / back·wide / front / others）**取值完全相同**，即 AE 控制器满足于比高对比场景所能承受的更亮的平均亮度 → 天空、窗边直接溢出；② 负责往回拉的高光恢复 **HLR 出厂即关**（`HlrOverRatioTH=0`，六个 variant 皆然），所以溢出后没有任何回调；③ `libSmartAEV2.so` 的日志串 `aeTarget: %d, curLuma: %d, ratio: %f, targetEV: %f` 证实 `Target` 就是这个 AE 亮度目标——调低它是单调的压暗拉回，不是整体降亮度（阴影靠曝光量自己回来）。

**实现**：面板数值输入框（0 / 100–250）。守护进程每次启动时用模块自带的**出厂原文** `camfix/SmartAE_back_orig.xml` 重建目标文件（只改 `<Target>`，主摄那份共 3 处、其余字节一模一样），再 **bind mount** 覆盖 `/odm/etc/camera/smartae/back/SmartAE.xml`。因为基准永远出厂、生成物即时重建，所以任何数值都可复现，不存在状态残留；不改分区、不动 dm-verity。相机 HAL 每次打开相机重读 tuning → **重开相机即生效，无需重启**。

- 取值建议：**200 = 出厂**，**185 = 本模块默认**（实机 A/B：同场景对比下 200 明显更糟），**170–195 = 合理区间**；低于 ~170 室内/暗光人脸会发灰闷（AE 会索要场景给不起的 ISO/快门）。0 = 关闭（plain umount 回出厂）。
- 细调交给使用者：面板输入框后面直接标了区间与代价，改完重开相机试两张即可，无需 root 命令、无需重启。
- 生效判定：`/data/adb/honor_charge_unlock.cam` = `on <当前值>`；面板「开关」卡那行直接显示 **相机 HAL 此刻真正读到的 Target**（挂载失败会显式告警，不静默）。
- 只做后置主摄。前置/长焦/超广出厂同值，若需要同样处理，扩 `CAM_TGT` 路径即可（每个镜头一份）。
- 与「高光恢复」是两件事：本轮只调 AE 目标；若把 Target 压下去后正常曝光下高光仍溢出，下一轮再动 `HlrType/HlrLv/HlrOverRatioTH/HighLightEVThd`（同文件明文）。

### 相机锐化抑制 · HDR+ 细节回加降幅（sharpen_cut，v2.0.0，默认 35）

**问题**：社区反馈「锐化太重」。逆向定论：HDR+ 引擎 `/odm/lib64/libhdrp.so` 里字面存着这些取值路径 —— `/Config/RAWNR/lanczos_de/{exp,iso}%d`、`/Config/RAWNR/DetailAddBack/Layer0..2/CurrentLayer/{exp,iso}%d` 以及 `CHANGEREFRAWNR` 的两份镜像，即它逐模块解析 `hdrp_mc.xml`；而同一份 `<Global>` 里 `RAW2YUV/sharpen` 出厂 `switch=0`、`DE/CE/DRE/SkinSmooth` 全部 bypass、只有 `RAWNRBypass=0` —— 也就是说真正在给主摄加锐的不是那些名字响亮的增强块，而是 **RAWNR 自己的细节回加 + lanczos 增强**。降这两处的增益就是治这个观感的正确抓手（`sharpen_cfg.xml` 的 `filter_data` 是纯位置化数组、字段无语义名，风险高，故不用它）。

**实现**：面板数值输入框（0–90，单位%）。守护进程按 `/odm/etc/camera/{hdrplite,rawhdr}/device.config` 里标 `_hpb_P`（后置主摄）的 8 个模块目录，各取 `hdrp_mc.xml` **先 umount 读出厂原文**、用模块内 `camfix/sharpen.awk` 生成降增益版本，再 bind mount 回去 —— 16 份文件（两棵树各 8 份，它们的标定数值彼此不同，所以必须逐份生成而非自带副本）。同样不改分区、不动 dm-verity，重开相机即生效。

- 改的是**哪些列**（依文件内自带的字段说明，按行内 token 序号取）：`lanczos_de` 取三个 `[0,512]` 定点增益组（nondetail 5–7、dark/light 10–11、Face 16–18），`DetailAddBack` 取 `weight_for_non_detail_region` 的 2 weight + 1 scale（13–15）与 `weight_for_detail_region` 的 3 weight + 1 scale（18–21）。所有阈值列、kernel 阶数、计数列一律不动。
- **行内 token 数不等于 47/18 就整行原样输出**，且只有整份文件命中完整 schema（≥100 行）才挂载 —— ROM 若改了列布局，结果是「不动」而不是「改坏」。
- 取值建议：**0 = 出厂**，**35 = 默认**，**20–50 = 合理区间**（20 基本看不出来，50 已明显偏软）；超过约 60 细节开始糊成涂抹感，面板封顶 90 但不建议常驻。0 = 关闭（16 份全部 plain umount 回出厂）。
- 生效判定：`/data/adb/honor_charge_unlock.shp` = `on <降幅> <已挂载>/<目标数>`；生成文件里带 `<!--shpN-->` 注释标记，面板那行 grep 这个标记显示 **相机 HAL 此刻真正读到的降幅**，并核对挂载份数（只挂上一半不会伪装成成功）。
- 社区四问：过曝 + 高光（`smartae_target`）、锐化（`sharpen_cut`）已落地；紫边（横向色差 CAC）在 `/vendor/etc/imgsensor/mt6993/*_ldy.bin` 加密 tuning 内，AP 侧无明文抓手，只能靠降锐化 + 压高光间接缓解（振铃白边与色边都会跟着减）。

## 安装

- KernelSU：管理器刷入 zip，或 `ksud module install honor_charge_unlock-v1.0.0.zip`
- Magisk：管理器刷入 zip
- 重启后生效（service.sh 在开机完成后自启守护进程）

## 配置 `/data/adb/honor_charge_unlock.conf`

```ini
screen_on_unlock=1        # 亮屏时解除限流（核心功能）
unlock_when_screen_off=0  # 熄屏也强制解锁（同时会绕过真实温控，慎开）
poll_interval=2           # 轮询秒数，系统 6~9s 会写回限值，勿设太大
temp_guard=450            # 电池温度 ≥45.0°C 时暂停解锁（安全阀，0=关闭保护）
protocol_poke=1           # 开机/插电时尝试写 pd/hvc/hsc 使能节点
include_lvc=1             # 同时重置 LVC 路径
fcm_unlock=1              # FCM 推送保活解锁（探测换源+冻结豁免+宽限保持）
fcm_interval=1800         # FCM 重申间隔（秒）
fcm_probe_urls=http://www.baidu.com,http://www.qq.com  # 探测源（需国内可达且返回 HTTP 200）
fcm_keepalive=1           # GMS 冻结豁免（notifyGoogleKeepAlive）
fcm_grace_keeper=1        # iAware 宽限标记保持
fcm_gms_on=1              # google_service_status 保持为 1
vpn_lock=0                # VPN锁定GMS框架：VPN隧道连上时自动套系统lockdown，断开自动解除
lsp_fix=0                 # LSPosed 系统作用域修复：开机早期掩 locale 让 lspd 跳过 NPE 分支（需 LSPosed v2.2.0+，重启生效）
volte_fix=1               # VoLTE 解锁：为在插 SIM 的运营商自动补 type=ims 接入点（国内外卡通用，缺行即补）
volte_radio_cycle=1       # 首次实际插入 ims 行后自动切一次飞行模式重建数据配置（0=不切，等重启）
qr_fix=1                  # 相机扫码修复：bind mount 禁用主摄码场景 QRFUSION 6 帧融合（拍码糊/对焦拉锯，0=还原）
smartae_target=185        # 相机曝光抑制：主摄 SmartAE 测光目标（出厂 200，推荐 170-195，0=关；重开相机生效）
sharpen_cut=35          # 相机锐化抑制：HDR+ 细节回加降幅%（出厂 0，推荐 20-50，封顶 90；重开相机生效）
verbose=0                 # 1=写日志 /data/adb/honor_charge_unlock.log
```

改完配置重启或手动重启守护进程生效。

## 手动操作

```sh
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh'          # 状态驾驶舱
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh diag'     # 全量诊断+仲裁日志(接真头后看)
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh pause'    # 暂停
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh resume'   # 恢复
```

v1.3.0 起守护进程会在**每次插头 8 秒后**自动把协议仲裁日志（adapter_type / support_mode / 仲裁 dmesg）追加到日志文件——插上 PD/UFCS 头再 `action.sh diag` 即可看到该头被仲裁到哪个协议、报了多少瓦。

## ⚠️ 为什么没有温控抑制功能（v1.5.1 撤回说明）

v1.4 曾尝试把 `disable_throttling` 策略（关 vtskin 皮肤温控）持久投递给 thermal_core。
实测该策略在**冷启动时致命**：vtskin 全关 → thermal_core 启动期 `plat_vtskin_info is NULL` →
mbrain 拿不到皮肤信息 → 开机链卡死 → hang_detect 看门狗强制重启 → 循环（pstore 已取证）。
运行期热替换虽然能活，但文件持久化后下次开机必炸，因此该功能整体撤出模块。
`thermal_conf_codec.py` 与解密配置保留在 magic8proair/_ext/ 仅供研究，**请勿再投递 vtskin-disable 类策略**。
v1.5.1 同时修复：pidfile 跨重启残留导致守护进程拒绝自启的 bug。

### 面板真实信号读数（v1.9.7，无开关无常驻）


QCI 图例：`5`=IMS 承载（VoLTE 语音/信令），`6/8/9`=上网承载。某张卡出现 `QCI:5` 即该卡 IMS 承载已建立（VoLTE 可用）；volte_fix 生效与否可直接看这里。

荣耀状态栏信号格子按自家 `levelHw` 绘制（RSRP -100 也能显示近满格），且不提供 dBm。真正的状态栏改动（LSP hook SystemUI 或重打包资源）必然引入 24h 常驻开销，与本模块"能不加耗电就不加"的原则冲突，因此做成**面板只读卡片**：打开 WebUI 时才执行几条 grep（`telephony.registry`），显示每张卡的运营商/制式/频段/RSRP dBM/SNR/5G 实测值；**关闭面板零开销**（无常驻进程、无轮询、无通知）。

## WebUI 仪表盘（v1.5.0）

KernelSU 管理器 → 模块详情 → **WebUI** 打开实时面板：
- 实时充电（状态/功率/电流/电压/温度/电量，功率与电流为 canvas 实时曲线）
- 充电协议实况（当前协议 / 握手档位 / 物理输入；电流统一在「实时充电」卡展示）
- 各协议有效档位 `iin_limit` 表、MT6379 充电 IC 参数、适配器协商结果、电池健康与循环次数
- 开关：充电状态下亮屏进行电流对抗 / 熄屏也对抗 / 启动拉满 / 禁用预加载 / FCM 保活 / **GMS推送·VPN 监控指示器** / 海外区域旁路 / **LSPosed 系统作用域修复** / **VoLTE解锁** / **相机扫码修复** + 滑动限频档位 + 守护暂停/重启
- 数据来源 `dashboard.sh`，每 2-3 秒刷新；接真实 PD/UFCS 头后适配器与协议字段会实时填充

## 逆向定论（完整证据链见工作区 docs/荣耀调度解锁逆向笔记.md，未公开）

- 亮屏限流写回者是**内核模块 `honor_charger_manager_mtk.ko`**：通过 LCD/framebuffer notifier 直接拿屏幕状态，按 `threshold_caculation_interval=5` 周期用 DTS 的 screen_on/off 电流表重算 `iin_thermal`。thermal policy（含 policy_02）与充电无关（thermal_core 中 0 引用），改热策略动不了它。
- PD/PPS/PE45 无隐藏功率表（模块未 strip 符号，.rodata 仅 480B）：瓦数 = 握手时适配器报价现算；`pd_max_watt` 日志即适配器 PDO 实时值。
- `enable_charger` 位图 = 仲裁引擎实时状态，非功能开关（pd/hvc=0 仅表示当前适配器下无该协议伙伴）。

## 风险说明

- `iin_thermal` 同时也是真实过热限流通道。亮屏解锁期间（`screen_on_unlock=1`）热软限流会被模块持续重置，默认 45°C 电池温度保护是唯一软闸；长时间亮屏快充请留意机身温度。硬件层的 JEITA / 充电 IC 保护仍然有效（未动）。
- 卸载模块后系统会在下一次屏幕/温控事件自动恢复原限值。

## v1.8.0 / v1.8.1 — CPU 频率治理（perfserv_freq QoS 通道，2026-09-07）

**逆向基础**（完整证据链见 `docs/充电逆向笔记.md`）：`/proc/powerhal_cpu_ctrl/perfserv_freq` 写格式 `<slot 0-7> <min> <max>`，原子替换该簇 PM-QoS min/max 票对（slot 0-3→policy0、4-6→policy4、7→policy7），last-writer-wins、无 TTL——续写方通吃，45Hz 续写实测 100% 占空比。

### launch_boost v2（app 启动全频拉满）

- 信号：ActivityManager "Start proc ... for [next-]top-activity"（过滤后台拉起）；结束：ActivityTaskManager "Displayed"（第一帧）或 `launch_boost_ms`（默认 2000，硬顶 5000）。
- 动作：三簇 min=max 钉满（p0 2.7G / p4 3.5G / p7 4.21G），10-30Hz 续写压过 perfserv 启动限频（原生 p4≤3.0G / p7≤3.5G）。
- 实测：冷启动窗口内满频 100%，Displayed 精确释放，perfserv 原生画像无缝接管。
- 注意：v1.6-v1.7 的 launch_boost 因 live conf 缺键从未激活过，v1.8.0 起补键生效。

### scroll_cap（滑动限频，淘宝 120Hz 阶梯实测调优）

- 触发：wakeup_sources event2 计数增量（真实触摸；合成注入不可见）；松手 400ms 释放。
- 动作：policy4 max 钳至 `scroll_cap`（QoS 票 ~20Hz 续写），launch boost 期间自动让位。
- 阶梯数据（每档 ~11s 合成连续滑动）：0.9G legacy janky 14.50% / **0.8G 13.75%（p99 21ms 反优，甜点）** / 0.7G 15.91% / 0.6G 21.67% / 0.5G 24.86%——0.7G 起单调劣化，p50 6→9ms 超出 120Hz 8.3ms 预算 → **默认 0.8G（v1.8.1）**。p0 小簇钳制实测再 +5% 劣化，默认关闭。

### 开销

全树实测 ≈3% 单核（小核）：fifo `read -t 0.1` 零 fork 节拍 + 5Hz 触摸轮询 + logcat 流；launch 窗口 30 写/s（单写 ~µs 级）。

### WebUI（v1.8.2 重写）

- **开关面板**：亮屏解锁 / 熄屏也解锁 / 启动拉满 / 禁用预加载 四个开关 + 滑动限频档位选择（关/0.9G/0.8G/0.7G/0.6G）+ 守护暂停/重启。改动写入 `/data/adb/honor_charge_unlock.conf`（`webui_ctl.sh set` 白名单校验）并自动重载守护，约 12s 全部生效。
- **状态修复**：`守护进程 ✕` —— 旧检测只认 pidfile 且在 WebUI 上下文读不到 /data/adb 时恒 0 → 现为 pidfile+cmdline 校验 + pgrep 回退；`被压制` —— 旧逻辑单次采样 iin_thermal（系统 4.4s 压回一次，撞窗 ~9% 概率误报，未充电/暂停时恒误报）→ 现为 3 次采样取 max + USB 在线/暂停状态区分（未充电显示“未充电”，暂停显示“已暂停”）。
- 新增 `LB_ACTIVE` 实时指示（启动拉满生效中）；守护启动时清理残留 flag。

### 更新检测（KSU updateJson）

模块 `module.prop` 带 `updateJson` 字段（指向 jsdelivr CDN 的 `update.json`）。KernelSU 管理器会周期拉取并比对 `versionCode`，发现新版后在模块页提示更新，点击即下载 `zipUrl` 安装。

发新版的完整动作：

1. `module.prop` bump `version` / `versionCode`
2. 打包 zip 放入 `dist/`，更新根目录 `update.json` 的 `version` / `versionCode` / `zipUrl` / `changelog`
3. commit + push（jsdelivr 与 raw 线路自动生效），可选创建 GitHub Release 附带 zip

`update.json` 同时存在于 jsdelivr（国内可达）与 raw.githubusercontent 两条线路。

### tools/ 说明

- `start_hcu.sh` 分离启动/重启守护；`restart_hcu.sh` 部署+冷启动验证；`diag_fg.sh` / `cleanup_fg.sh` / `check_fg.sh` / `restart_fg.sh` 进程树运维；`ladder_tb.sh` 淘宝滑动阶梯复测；`legacy_freqgov/` 独立版原型存档（已合并）。
- `docs/充电逆向笔记.md` 为本机全量逆向工作底稿（充电子系统 + CPU 调度栈 + ADPF）。
