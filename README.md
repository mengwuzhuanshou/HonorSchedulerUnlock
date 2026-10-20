# Honor Scheduler Unlock (MTK) — 荣耀调度解锁模块

> ⚠️ **AI 生成声明 / AI-generated**：本模块的逆向分析、代码与文档均由 AI 生成并在实机实测；
> 请自行评估风险后使用。

纯 root 脚本模块（KernelSU / Magisk 双兼容），不依赖 Xposed。核心功能：

- **充电电流对抗**：亮屏 / 熄屏全程对抗充电热限流，SCP / UFCS 直充满档；
- **CPU 频率治理**：app 启动时三簇满频，滑动时大簇降频省电（默认 0.8G）；
- **FCM 推送保活**：国行 ROM 谷歌连通性探测换源，防 GMS 被断网 / 断推送；
- **VoLTE 解锁**：为缺 `ims` 接入点的运营商自动补行，国内外卡通用；
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

**亮屏限流原理**：`thermal_core` 与内核充电算法按屏幕状态 / 温度场景，把限流写入
`/sys/class/hw_power/charger/direct_charger_{sc,hsc}/iin_thermal`（mA）。亮屏时
SCP/UFCS 被压到约 5000–6500mA，熄屏约 6400mA；写 `0` 后充电固件重算为该路径满档
（**sc=12000 / hsc=14500**）。系统每隔数秒（实测 4–9s）会写回场景值，守护进程以
0.3s 周期夺回，实测占空比 ≈95%，低谷 ≤0.4s。

**协议档位**（DTS 实测）：

| 路径 | product_max_pwr | 适配器最高电压 | 满档电流 |
|---|---|---|---|
| sc (SCP) | 66000 (66W) | 11V | 12000mA |
| hsc (UFCS) | 80000 (80W) | 21V | 14500mA |
| lvc | — | 5.5V | 4500mA |

档位是写满的：SCP 66W / UFCS 80W 双规格，UFCS 协商上报 80W；`ui_max_pwr=40W`
只是界面显示口径，不存在被隐藏的更高档。PD 3.1 物理通路在，但 `enable_charger`
位图为只读节点，PD/PPS 是否置位取决于适配器；PPS 随 PD APDO 生效。

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

**海外区域旁路（`region_bypass`，默认关）**：`post-fs-data` 阶段
`resetprop -n msc.config.optb 392`（非持久，关掉重启即恢复国行身份）。国行身份
（optb==156）被 PGGoogleServicePolicy / PowerGenie / iAware 在进程启动时读一次，
翻转后整条国行谷歌管控链不布防，FCM 解锁退化为纯保险。本质是模拟海外卡用户；
副作用包括 COTA 国行参数包停发、**OTA 可能收不到国行推送**、通知铃声选不了「无声」
等区域化行为变化。国内使用请勿开启。

**LSPosed 系统作用域修复（`lsp_fix`，默认关，重启生效）**：荣耀魔改的 `PackageParser`
解析系统作用域模块时调用 `HnPackageUtils.notNeedCustomedPermission()` →
`ActivityManager.isSystemReady()`，在 lspd daemon 进程内必然 NPE，模块被静默跳过。
NPE 位于 CN locale 专属分支（`isChinaVersion()` 读 `ro.product.locale.*`）；本开关在
`post-fs-data`（zygote 之前、lspd 解析模块列表之前）把 locale 临时改为 `en/US`，
该分支被跳过，`sys.boot_completed` 后 5 秒恢复 `zh/CN`。需要 LSPosed v2.2.0+
（Zygisk Next）；非荣耀/非 CN locale 下开着也无害；上游若内置修复可关闭。

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

## 安装

- KernelSU：管理器刷入 zip，或 `ksud module install honor_charge_unlock-<version>.zip`
- Magisk：管理器刷入 zip
- 重启后生效（`service.sh` 在开机完成后自启守护进程）

## 配置 `/data/adb/honor_charge_unlock.conf`

```ini
screen_on_unlock=1        # 亮屏时解除限流（核心功能）
unlock_when_screen_off=1  # 熄屏也强制解锁（默认开；会绕过真实温控，介意设 0）
poll_interval=0.3         # 轮询秒数；系统数秒内会写回限值，勿设太大
temp_guard=0              # 电池温度 ≥ 该值（0.1°C）时暂停解锁；0=关闭保护
max_iin=20000             # 写入 iin_thermal 的显式上限（内核按温度档钳位）
protocol_poke=1           # 开机/插电时尝试写 pd/hvc/hsc 使能节点
include_lvc=1             # 同时重置 LVC 路径
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
region_bypass=0           # 海外区域旁路（模拟海外卡，副作用见正文）
vpn_lock=0                # GMS推送·VPN监控指示器（只观察，不写 VPN 配置）
lsp_fix=0                 # LSPosed 系统作用域修复（需 v2.2.0+，重启生效）
volte_fix=1               # 为在插 SIM 补 type=ims 接入点（国内外卡通用）
volte_radio_cycle=1       # 首次插入 ims 行后切一次飞行模式重建数据配置
qr_fix=1                  # 扫码场景禁用主摄 QRFUSION 6 帧融合
smartae_target=185        # 主摄 SmartAE 目标（出厂 200，推荐 170-195，0=关）
sharpen_level=2           # 主摄 EE 锐化档位（0=关/出厂，1=×1.25，2=×1.5，3=×2.0，4=×2.5）
beauty_cut=30             # 前置人像磨皮/美型降幅%（出厂 0，推荐 10-50；拍照页自拍尚未覆盖，修复中）
uw_exp_ms=910             # 超广 0.7x 暗光曝光上限 ms（出厂 200，0=关，150-999）
uw_iso_gain=100           # 超广 AE 表 ISO 增益%（出厂 100，100-250；≥150 实测偏红）
verbose=0                 # 1=写日志 /data/adb/honor_charge_unlock.log
```

改完配置重启或手动重启守护进程生效。

## 手动操作

```sh
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh'          # 状态驾驶舱
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh diag'     # 全量诊断+仲裁日志
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh pause'    # 暂停
su -c 'sh /data/adb/modules/honor_charge_unlock/action.sh resume'   # 恢复
```

每次插头 8 秒后会自动把协议仲裁日志（adapter_type / support_mode / 仲裁 dmesg）
追加到日志文件；插上 PD/UFCS 头再 `action.sh diag` 可看该头被仲裁到哪个协议。

## WebUI 仪表盘

KernelSU 管理器 → 模块详情 → **WebUI**：

- 实时充电（状态/功率/电流/电压/温度/电量，canvas 曲线）、协议实况、各协议
  `iin_limit`、MT6379 参数、适配器协商结果、电池健康与循环次数；
- 开关：亮屏对抗 / 熄屏也对抗 / 启动拉满 / 禁用预加载 / FCM 保活 / VPN 监控 /
  海外区域旁路 / LSPosed 系统作用域修复 / VoLTE 解锁 / 相机扫码修复 / 主摄锐化 / 前置美颜 /
  超广角长曝与 ISO 增益 + 滑动限频档位；
- 只读信号卡：打开面板时执行几条 `telephony.registry` 查询，显示每张卡的运营商/
  制式/频段/RSRP/SNR/5G 实测值；**关闭面板零开销**（无常驻、无轮询、无通知）。
  荣耀状态栏信号格按自家 `levelHw` 绘制且不提供 dBm，故不做状态栏改动。

## 风险与限制

- `iin_thermal` 同时是真实过热限流通道。出厂配置 `temp_guard=0`（温度软闸关闭）
  且 `unlock_when_screen_off=1`（熄屏也对抗），软件层剩下的钳位是内核 `temp_para`
  阶梯。需要保守策略时把 `temp_guard` 设为 450（45.0°C），并考虑
  `unlock_when_screen_off=0`；硬件 JEITA / 充电 IC 保护仍然有效（未动）。
- 卸载模块后系统会在下一次屏幕/温控事件自动恢复原限值。
- MCS 绕过 bypassable VPN 是 GMS 行为，模块无法修；只能换非可旁路/全局 VPN。
- 海外区域旁路副作用不止文中列出的几项，国内使用请勿开启。
- 内核 `temp_para` 的温度阶梯 ≥44°C 时用户态无法绕过（需重编 DTB），属引导镜像工程。
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
