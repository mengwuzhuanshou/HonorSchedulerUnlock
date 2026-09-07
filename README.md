# Honor Scheduler Unlock (MTK) — 荣耀调度解锁模块

> ⚠️ **AI 生成声明 / AI-generated**: 本模块的逆向分析、代码与文档均由 AI 生成，并在下述设备上完成实测；请自行评估风险后使用。

纯 root 脚本模块（KSU / Magisk 双兼容），不依赖 Xposed。功能：**充电时亮屏解锁皮肤温控限流**（SCP/UFCS 直充满档）+ **app 启动时 CPU 满频率** + **滑动时 CPU 降频省电**（大簇 0.8G）。

## 适用范围（重要）

| | 充电解锁（皮肤温控限流） | app启动满频 / 滑动限频 |
|---|---|---|
| ✅ 实测可用 | 荣耀 Magic8 Pro Air（LDY-AN00，天玑 **9500** / MT6379 / MagicOS 10）——全部开发与测试在此设备完成 | 同左 |
| 🟡 理论可适配（未实测） | 其它荣耀 MagicOS + 天玑(MTK) 机型：需存在荣耀直充节点 `/sys/class/hw_power/charger/direct_charger_*` 与 MT6379 系充电 IC | 其它 MTK perfserv 架构机型：需存在 `/proc/powerhal_cpu_ctrl/perfserv_freq`（powerhal_cpu_ctrl.ko） |
| ❌ 不适用 | 荣耀高通(Qualcomm)机型（充电栈完全不同）、非 MagicOS | 高通机型（无 MTK perfserv 栈）、无 root |

安装时若 `/sys/class/hw_power/charger/direct_charger_hsc` 不存在（customize.sh 会提示），充电解锁功能在本机无效；CPU 部分取决于 `/proc/powerhal_cpu_ctrl/` 是否存在。

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

## WebUI 仪表盘（v1.5.0）

KernelSU 管理器 → 模块详情 → **WebUI** 打开实时面板：
- 实时充电（状态/功率/电流/电压/温度/电量，功率与电流为 canvas 实时曲线）
- 协议仲裁位图（dcp/hvc/pd/lvc/sc/mainsc/auxsc/hsc/wl_sc 逐项亮灭）
- 直充三路热限流实时值/满档进度条（lvc 5.5V / sc SCP 11V / hsc UFCS）
- 各协议有效档位 `iin_limit` 表、MT6379 充电 IC 参数、适配器协商结果、电池健康与循环次数
- 数据来源 `dashboard.sh`，每 2 秒刷新；接真实 PD/UFCS 头后适配器与协议字段会实时填充

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

### tools/ 说明

- `start_hcu.sh` 分离启动/重启守护；`restart_hcu.sh` 部署+冷启动验证；`diag_fg.sh` / `cleanup_fg.sh` / `check_fg.sh` / `restart_fg.sh` 进程树运维；`ladder_tb.sh` 淘宝滑动阶梯复测；`legacy_freqgov/` 独立版原型存档（已合并）。
- `docs/充电逆向笔记.md` 为本机全量逆向工作底稿（充电子系统 + CPU 调度栈 + ADPF）。
