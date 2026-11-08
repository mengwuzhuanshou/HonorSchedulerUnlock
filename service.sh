#!/system/bin/sh
# Honor Charge Unlock daemon - KSU/Magisk compatible
# Votes the input-current lanes (interface/iin_limit) up to max_iin against the
# OS's own thermal cap. The node grammar - and why the vote has to be released
# the way it is - are documented at do_unlock/iface_snapshot below.
MODDIR=${0%/*}
. "$MODDIR/state.sh"
st_init
CONF=$ST/conf
LOG=$ST/log
PIDF=$ST/pid

BATT_UE=/sys/class/power_supply/battery/uevent
IFACE=/sys/class/hw_power/interface
DC=/sys/class/hw_power/charger
AICR=/sys/class/power_supply/primary_chg/input_current_limit
ICHRG=/sys/class/power_supply/primary_chg/constant_charge_current

# ---------- config ----------
screen_on_unlock=1
unlock_when_screen_off=1
poll_interval=0.3
temp_guard=0
protocol_poke=1
verbose=0
# mA we vote for every unlocked lane. The kernel parser wants a specific
# grammar per node family (see do_unlock), and v2.2.0 had it wrong. A large
# number is safe:
# the kernel registry min-aggregates every user's vote and the adapter contract
# caps below it - thermal dcp 3000/4000 on a 21V/4A head still served
# primary_chg/input_current_limit 2000000.
max_iin=20000
# lanes re-voted on interface/iin_limit. Only `dcp` belongs here: the vendor
# re-votes dcp through this same node, so eff changes and our re-assert fires.
# On sc/hsc the vendor writes the per-device iin_thermal node DIRECTLY (no voter
# ever registers - vote_object shows none), and power_vote_set ignores a
# same-value re-vote once applied (latch at vote_obj+0x44, proven live
# 2026-11-08: same vote after a vendor overwrite left the row at the vendor
# value). Those lanes are fought by dciin_push below instead. Empty = no vote.
iface_lanes="dcp"

# PD ceiling push. AICR and ICHG are the charger-IC *result* nodes: the kernel
# charger_control 'default' voter re-asserts 1400mA / 2300mA every ~10s (battery
# in the 10-44.9C JEITA band), so voting lanes alone never moves them past the
# min. Read-before-write, re-assert only after the OS pulls them back -> about
# one write per 10s, not a per-cycle loop. Measured on the 65W PD head (9V/3A
# PDO): AICR 3A + ICHG 4A -> battery 2.98 -> 3.97A, ibus 1.80 -> 2.53A, input
# 15.7 -> 22W, 34.9 -> 37.1C. 4A equals constant_charge_current_max, the BUCK
# path ceiling (2026-11-05); above the PD contract the source caps the result.
aicr_unlock=1
aicr_target=3000000
ichg_unlock=1
ichg_target=4000000
# Release the push at this battery temp (degC*10). JEITA t3=45C already drops
# ICHG to 1750mA / CV 4080mV and t4=50C stops charging; stop just before that
# band so the firmware ladder, not our write, owns it.
pd_temp_guard=440

# Stock-head (SCP/UFCS) input-current fight on the per-device nodes
# charger/direct_charger_<dev>/iin_thermal. This is the node powergenie itself
# writes, so it is last-writer-wins with no vote latch: the daemon re-asserts
# only when the value drops below what our last write landed (read-back after
# write), about one write per vendor re-assert, not per poll. The kernel clamps
# every write to the temp_para row (sc 12000 / hsc 14500 at 10-44C, stepping down
# from 44C), so the vendor thermal ladder still owns the ceiling. This is the
# path the dcp interface vote can never reach: on a stock direct-charge head the
# buck is off and adapter current follows the sc/hsc thermal storage
# (sc_di+0x143c -> dc_thermal_get_max_charging_current -> get_max_chg_cur(9) ->
# select_charging_param -> regulation -> adapter_set_output_current).
dc_iin_unlock=1
dc_iin_devs="sc,hsc"

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
# Honor Charge Unlock config (values take effect after daemon restart or reboot)
# 1 = on, 0 = off
screen_on_unlock=1
# also force limits while screen is off (default on: full-time unlock)
unlock_when_screen_off=1
# poll interval in seconds (fractional ok). the OS re-caps limits every ~4.5s;
# 0.3s keeps the unlocked value up ~90% of the time
poll_interval=0.3
# pause unlocking when battery temp >= this (degC*10). 0 disables the guard.
# When it trips, the daemon now hands the lanes back (do_release writes the
# values it found before taking over), so the vendor temp_para ladder serves
# in full whenever we are not the one voting.
temp_guard=0
# PD ceiling push (uA). The kernel re-asserts AICR 1400mA / ICHG 2300mA every
# ~10s; the daemon re-writes only after it sees them pulled back. 0 disables
# either half. ICHG default 4000000 = constant_charge_current_max, the BUCK path
# ceiling; above the adapter contract the PD source caps the result.
aicr_unlock=1
aicr_target=3000000
ichg_unlock=1
ichg_target=4000000
# stop the PD push at this battery temp (degC*10); 440 = 44.0C, just below the
# JEITA 45C band (ICHG 1750 / CV 4080) and the 50C charge-stop.
pd_temp_guard=440
# stock SCP/UFCS head fight on charger/direct_charger_<dev>/iin_thermal (the
# node powergenie writes; last-writer-wins, clamped to the temp_para row so the
# vendor thermal ladder keeps the ceiling). 0 disables; devs comma-separated.
dc_iin_unlock=1
dc_iin_devs=sc,hsc
# try poking protocol enable nodes (pd/hvc/hsc) on boot and charger plug
protocol_poke=1
# launch boost v2: pin min=max on all clusters via perfserv_freq QoS votes
# for the launch window (ends at ActivityManager "Displayed" first frame or
# launch_boost_ms timeout, whichever first). Renewal-dominant: the proc write
# replaces the per-cluster PM-QoS min/max vote PAIR atomically and the last
# writer owns it, so a ~10-30Hz re-pin wins the race against perfserv's own
# launch caps (p4<=3.0G / p7<=3.5G) -> whole window runs at cluster max.
launch_boost=1
launch_boost_ms=2000
# scroll clamp: policy4 (big cluster) max in kHz while the finger is down,
# same QoS vote channel (100% occupancy measured at >=10Hz renewal).
# Touch source = wakeup_sources event2 counter (real touches only).
# Taobao 120Hz ladder (2026-09-07): 0.8G == 0.9G frame pacing (legacy janky
# 13.75% vs 14.50%, p99 21 vs 26ms), 0.7G+ degrades monotonically -> 0.8G.
scroll_cap=800000
# keep iAware app-preload features off (cloud may re-push values)
disable_preload=1
# --- FCM keep-alive unlock (v1.9; mechanism notes in docs/FCM通路逆向笔记.md) ---
# Honor China ROM probes "google connectivity" by HTTP-GETting google.com; on
# failure it silently drops GMS partial wakelocks (MCS push dies in doze),
# PowerGenie firewall-blocks the GMS uid, and after a 7-day grace iAware strips
# GMS apps of their background privileges. All three layers key off that probe.
fcm_unlock=1
# probe re-assert interval (seconds); also re-runs the keepalive/grace/gms keeps
fcm_interval=1800
# URLs fed to the probe (must answer HTTP 200, be reachable in CN; probe stops
# at the first success). Oversea-SIM devices short-circuit to OK anyway.
fcm_probe_urls=http://www.baidu.com,http://www.qq.com
# notifyGoogleKeepAlive(com.google.android.gms, true): freeze-exempt + unfreeze GMS
fcm_keepalive=1
# keep persist.sys.iaware_google_conn="0,1" so every boot starts a fresh 7-day grace
fcm_grace_keeper=1
# keep Settings.Secure google_service_status=1 (google components enabled)
fcm_gms_on=1
# region identity (v2.2.1, was the region_bypass on/off switch): post-fs-data
# pins BOTH region levers - msc.config.optb and ro.product.locale.* - before
# zygote, so the static-final gates latch the chosen identity for the whole
# boot. default = never touch either (stock per-boot values).
#   cn       -> optb 156 + zh/CN  (pin the China-market identity)
#   overseas -> optb 392 + en/US  (China-market gates stay disarmed)
region_mode=default
# vpn_lock (v1.9.3): GMS MCS unwraps "bypassable" VPNs and direct-connects
# mtalk.google.com (GMS design, no internal flag - see docs/FCM通路逆向笔记.md
# §15). While a VPN tunnel is up, re-point the system's always-on VPN at the
# connected VPN app with lockdown=1 via the vpn_management binder: lockdown
# overrides isBypassable to false AND netd blocks the underlying network, so
# MCS can only use the tunnel. The lock is held only while the tunnel is up
# (released on drop) and never persisted (settings scrubbed right after
# apply), so a reboot can never force-start the VPN blind.
vpn_lock=0
# lsp_fix (v1.9.5): let system-scope LSPosed modules inject into
# system_server on Honor MagicOS. The ROM's PackageParser NPEs inside the
# lspd daemon (ActivityManagerInternal null in non-system_server) when it
# parses such modules, and the NPE sits behind a CN-locale-only gate.
# post-fs-data masks ro.product.locale to en-US for the parse window (early
# boot); this daemon restores zh-CN a few seconds after boot_completed.
# Needs LSPosed v2.2.0+ (Zygisk Next). Takes effect after a reboot.
lsp_fix=0
# thirdparty_home (v2.3.0): allow a third-party launcher (e.g. Niagara) to be set
# as the default home without turning lsp_fix on. Honor has two gates, both in
# system_server: (1) PackageManagerService reports
# android.software.home_screen as unsupported when ro.product.locale.region is CN
# and ro.build.characteristics is "default"/"tablet" (static-final latch), and
# (2) the AntiMal launcher check forwards to the system manager engine, which
# allows as soon as that feature is true. post-fs-data masks ONLY
# ro.build.characteristics to "phone" for the pre-zygote window; locale/region
# are left alone, so this is independent of lsp_fix and region_mode. The daemon
# restores the stock value as soon as the feature reads true (early, so the
# display-engine capsules are not affected). Takes effect after a reboot.
thirdparty_home=0
# volte_fix (v1.9.6): CN ROM ships its telephony APN DB without a type=ims
# entry for many carriers (au/KDDI 44054 here; overseas VoLTE-only networks,
# but also domestic carriers whose ims row the ROM omits - carrier-agnostic).
# Without an ims APN the IMS PDN is never established, so VoLTE registration
# is dead and the CS domain spins in NOT_REG_SEARCHING forever (constant extra
# modem signaling = standby drain). Idempotently adds one type=ims row per
# loaded SIM's operator numeric - any SIM missing its ims row gets one.
volte_fix=1
# after a first-time ims APN insert, cycle airplane mode once so the data
# stack rebuilds its profiles without a reboot (runs right after boot, and
# only when a row was actually inserted - never on later checks)
volte_radio_cycle=1
# qr_fix (v1.9.8): camera QR-scan fix. This ROM has no dedicated AF scenario
# for the QR/document scene, and the rear-main 6-frame airaw pipeline runs
# the QRFUSION multi-frame fusion for it; with AF hunting between focus peaks
# on the high-contrast QR pattern, the fused burst ghost-blurs captures
# (repeat zoom-in/out hunting needed before a scan succeeds). The module's
# qrfix/facemaskconfig.xml (QRFUSION mask entry removed) is bind-mounted over
# /odm/etc/camera/airaw/facemaskconfig.xml by post-fs-data at boot; the
# runtime branch below applies/unmounts it when the switch is toggled via the
# panel (webui_ctl restarts the daemon). No partition write, dm-verity
# untouched, off = plain umount. Default on: user-verified sharper scans.
qr_fix=1
# eid_guard (v2.2.2): the eSIM EID-mismatch power-down bypass (the slot-2
# "当前使用的非法 eSIM 无法与设备匹配，已将该卡禁用" dialog). IN THIS MODULE, no
# extra LSPosed APK: an 8-byte splice makes native getOeminfoEid() return empty,
# which is one of the three ways checkCardEid() decides not to forbid.
# OFF BY DEFAULT because that same getter also feeds the activation-code path:
# with the guard on, adding a domestic-carrier eSIM by activation code fails
# until the switch is turned off and the phone is rebooted.
eid_guard=0
# smartae_target (v1.9.9): rear-main AE luma target, the exposure knob the
# community asks for (reports: 过曝 / 高光压不住). Factory 200 and IDENTICAL in
# all six smartae variants (/odm/etc/camera/smartae/back{,/aperture,/tele,/wide}
# + front + others), i.e. the AE is content to average brighter than a
# high-contrast scene can hold -> sky/window edges clip and nothing pulls them
# back (HLR is also factory-off: HlrOverRatioTH=0). libSmartAEV2.so logs
# "aeTarget: %d, curLuma: %d, ratio: %f, targetEV: %f" -> Target is exactly that
# AE luma target, so lowering it is a monotonic darkening pull-down.
# Only /odm/etc/camera/smartae/back/SmartAE.xml is touched (rear main); the
# <Target> tag appears 3x there and nothing else in the file changes.
# Value: 0 = off (factory behaviour), otherwise written into <Target>.
#   200 = factory  185 = default (user-accepted round-1 value)
#   170-195 = sane band; below ~170 indoor/low-light faces go muddy-grey
#   (the AE then demands more ISO/shutter than the scene has) and above 195
#   the change stops being visible. Not a brightness slider: it re-centres AE,
#   so shadows lift back via exposure, the whole frame does not just dim.
# Delivered as a bind-mount over EROFS /odm like qr_fix: generated at runtime
# from camfix/SmartAE_back_orig.xml (never modified -> any value reproducible),
# no partition write, dm-verity untouched, off = plain umount. The camera HAL
# re-reads tuning on each camera open, so a change lands on reopening camera
# (no reboot needed). Default 185.
smartae_target=185
# sharpen_level (v2.2.0): rear-main sharpening tier. The MTK ISP EE stage in the
# tuning DB is what actually sharpens the rear main; the v2.0.0 HDRP-XML route
# (sharpen_cut) was disproven on-device and is retired. Each tier scales the
# per-ISO-block H1_GN and MASTER_GN_POS/NEG fields of the shared EE table, so the
# factory relative strength between blocks is kept.
#   0 = off (factory)   1 = x1.25   2 = x1.5 (default, on-device A/B)
#   3 = x2.0 (unmeasured)   4 = x2.5 (unmeasured)
# Higher tiers also amplify ISO noise/grain. The factory ISP_param.db is
# sha256-pinned and delivered as 4096-byte page patches + bind mount (this ROM has
# no sqlite3); no partition write, dm-verity untouched, a different ROM build is
# left untouched. Lands on the next camera open (no reboot). Default 2.
sharpen_level=2
# beauty_cut (v2.0.1): community question 3 (前置磨皮/美颜很奇怪). The front
# beauty engine reads its effect curves from /odm/etc/camera/hwbeauty/front/
# hwbeauty_params.xml (device.config maps the front modules c848utf/caeuncy to
# that dir). Each effect is a named, integer, per-beauty-level array (10 numbers
# = level 1..10), laid out as Mode x ParamterSet(gender/skin/age). The factory
# curves in the main 11-35 female set are aggressive - SkinSoften reaching 100,
# FaceSlender 95, EyeEnlargement 55 - which is exactly what reads as over-smoothed
# / waxy / de-shaped in selfies. This knob scales those intensity curves toward
# the gentler end by a percent.
# Only whitelisted integer effect rows are touched; float preview/ratio rows
# (Preview_*, SkinQualityRatio, EnvLumaRatioSet) and index/threshold tags
# (SkinToneStyle, SkinTone, ToneSet) are emitted byte-identical, and cut=0
# round-trips the whole file exactly (its final line has no trailing newline;
# camfix/beauty.awk is told via eofnl so it neither adds nor drops one). Rows
# are rewritten only when the tag is whitelisted AND all body tokens are integer,
# so a relayout degrades to "no edit" instead of a half-mangled tuning.
# Value: percent those intensities are reduced by. 0 = off (factory), 1..90.
#   30 = default   10-50 = sane band (10 subtle, 50 clearly more natural)
#   above ~60 the slim/enlarge pullback is strong enough that face shape reads
#   wider/less-corrected than users expect, and skin texture starts showing.
# Scope: two bind-mounts, front camera only (rear/back modules untouched). The
# engine chooses the file by styleMode: photo-page selfie (styleMode 0) reads
# hwbeauty_params_lp.xml, 人像 and the other styles read hwbeauty_params.xml, so
# both are bound with the same transform (the photo-page gap this closes was
# first written up as a known gap in v2.0.1).
# Same stateless umount->awk-transform->bind-mount delivery as the other camfix
# knobs: no partition write, dm-verity untouched, lands on reopening the camera,
# off = plain umount. Default 30.
beauty_cut=30
# uw_exp_ms / uw_iso_gain (v2.1.0): ultra-wide 0.7x low-light brightness. This
# ROM's app never routes a multi-frame night pipeline for the UW camera (the
# 0.7x "night" shot has the same EXIF as normal photo: 200ms/ISO4000), so the
# only honest lever is one-frame exposure vs gain. 3A caps exposure at
# 1e9/target_fps - 46000ns and the metastore builder hardcodes target fps=5
# (199.954ms). This knob raises the AE pline table 311 (calxncy_m030_UW_SN)
# last-anchor eMax (factory 200000us) and, when needed, rewrites the four
# `mov w8,#5` in libmtkcam_metastore.so to fps=2 (cap 499.954ms) or fps=1
# (cap 999.954ms). uw_iso_gain scales the 17 anchors' isoMin/isoMax pair.
# Measured on LDY-AN00: 910ms/ISO4000 -> EXIF 0.9100015s, luma 26.0, R/G 1.58;
# 160% -> ISO6400 but AE trades exposure down to 700ms, luma 33.5, R/G 2.71
# (red cast). Main-camera night reference: luma 42.5-43.1, R/G 1.75-2.01. So the
# default keeps ISO at 100% (no color cast first) and exposure at 910ms (the
# same total exposure the main camera uses for night: 7 x 130ms).
# Range: uw_exp_ms 0=off (factory 200ms), 150-999ms; uw_iso_gain 100-250%.
# Both factory inputs are sha256-pinned; a mismatch leaves the camera untouched.
# Delivery is bind-mount only (no partition write, dm-verity untouched). The
# .so is mapped when camerahalserver starts, so a change kills the HAL and the
# camera app must be reopened (no reboot).
uw_exp_ms=910
uw_iso_gain=100
verbose=0
EOF
fi
# shellcheck disable=SC1090
. "$CONF" 2>/dev/null

# merge keys added by upgrades into existing confs (template above is only
# written on first install; never clobber values already present)
conf_add() {
  grep -q "^$1=" "$CONF" 2>/dev/null || echo "$1=$2" >> "$CONF"
}
conf_add screen_on_unlock 1
conf_add unlock_when_screen_off 1
conf_add poll_interval 0.3
conf_add temp_guard 0
conf_add protocol_poke 1
conf_add max_iin 20000
conf_add iface_lanes "dcp"
conf_add aicr_unlock 1
conf_add aicr_target 3000000
conf_add ichg_unlock 1
conf_add ichg_target 4000000
conf_add pd_temp_guard 440
conf_add dc_iin_unlock 1
conf_add dc_iin_devs sc,hsc
conf_add launch_boost 1
conf_add launch_boost_ms 2000
conf_add scroll_cap 800000
conf_add disable_preload 1
conf_add fcm_unlock 1
conf_add fcm_interval 1800
conf_add fcm_probe_urls "http://www.baidu.com,http://www.qq.com"
conf_add fcm_keepalive 1
conf_add fcm_grace_keeper 1
conf_add fcm_gms_on 1
# v2.2.1: the region_bypass on/off switch became the region_mode tri-state.
# Carry an explicit "on" over to "overseas"; anything else starts at default.
if ! grep -q '^region_mode=' "$CONF" 2>/dev/null; then
  case "$(sed -n 's/^region_bypass=//p' "$CONF" 2>/dev/null | head -n 1)" in
    1) echo 'region_mode=overseas' >> "$CONF" ;;
  esac
fi
conf_add region_mode default
conf_add vpn_lock 0
conf_add lsp_fix 0
conf_add thirdparty_home 0
conf_add volte_fix 1
conf_add volte_radio_cycle 1
conf_add qr_fix 1
conf_add eid_guard 0
conf_add smartae_target 185
# v2.2.0: sharpen_cut is retired with its HDRP-XML route. Migrate an explicit 0
# (user had sharpening off) to the new tier 0; everything else starts at x1.5.
if ! grep -q '^sharpen_level=' "$CONF" 2>/dev/null; then
  case "$(sed -n 's/^sharpen_cut=//p' "$CONF" 2>/dev/null | head -n 1)" in
    0) echo 'sharpen_level=0' >> "$CONF" ;;
    *) echo 'sharpen_level=2' >> "$CONF" ;;
  esac
fi
conf_add beauty_cut 30
conf_add uw_exp_ms 910
conf_add uw_iso_gain 100
conf_add verbose 0
# re-source: conf_add only appends to the file, but an upgraded conf means the
# first source above ran without the new keys -> without this, fcm_* stay
# empty until the next reboot (same class of bug as the v1.8.0 template lesson)
. "$CONF" 2>/dev/null

log() {
  [ "$verbose" = "1" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null)
  if [ "${sz:-0}" -gt 32768 ]; then : > "$LOG"; fi
  echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"
}

screen_awake() {
  # Awake/Dozing/Asleep; Dozing can still be "display off" -> only Awake counts
  dumpsys power 2>/dev/null | grep -qm1 'mWakefulness=Awake'
}

# The interface files are NOT a plain number. The kernel parser wants
# "<user> <lane> <mA>" and rejects anything else outright:
#   echo 20000 > interface/iin_thermal   -> [E/power_if] unable to parse input:20000
#   echo dcp 2000 > ...                  -> unable to parse input:dcp 2000
# which is all v2.2.0 ever achieved on this file family (both of its writes),
# at poll_interval, i.e. the "fight" never started on ANY head - and on a
# PPS/BC12 head there is no SCP/HSC lane to fall back on either, so those users
# saw nothing at all. Measured with the grammar (2026-11-02, battery Full):
#   thermal dcp 2000/3000/4000 -> interface/iin_limit row AND
#   charge_data/iin_rt_current 1000 -> 2000/3000/4000 AND
#   primary_chg/input_current_limit 1000000 -> 2000000 (-> mt6379 AICR write)
# How to read the row back: it is the `thermal` user's own vote capped by a
# per-lane ceiling - dcp takes 20000 as-is, lvc/sc/hsc stay on their temp_para
# row (4500/12000/14500) no matter what is written. A 0 vote means "thermal does
# not vote" and the row then shows the next voter (2500 on dcp), NOT a limit of
# zero; hota_iin_limit/startup_iin_limit read that way (`dcp 0 lvc 0 sc 0 hsc 0`).
#
# Read before writing, because the kernel logs EVERY accepted write
# ([I/power_if] sysfs_set=iin_limit ...) and a blind re-assert at poll_interval
# measured ~20 kmsg lines/s - that rolls the ring buffer in about a minute and
# eats the arbitration evidence of the next plug event. `fight` counts the
# re-asserts, so every one of them is the OS taking a lane back: the fight itself.
do_unlock() {
  for l in $iface_lanes; do
    v=$(grep -m1 "^$l " "$IFACE/iin_limit" 2>/dev/null)
    [ "${v#"$l "}" = "$max_iin" ] && continue
    echo "thermal $l $max_iin" > "$IFACE/iin_limit" 2>/dev/null
    fight=$((fight + 1))
  done
  dciin_push
  unlock_pd_limits
}

# The per-device charger/direct_charger{,_sc,_hsc}/iin_thermal nodes clamp every
# write to the temp_para row ("val is too large: 20000, tuned as default") and
# read back the CLAMPED value, never 20000 - the 2026-11-04 measurement misread
# that as "writes could not help". They do land: 2026-11-08 live proof, vendor
# sc=6947 -> write 20000 -> both this node and the interface row read 12000 (the
# 33C temp_para row), restore 6947 -> both follow. dciin_push below fights on
# exactly these nodes with a landed-value tracker so the clamp error is logged
# once per vendor re-assert, not per poll.

# Do NOT "release" by writing 0: measured, `thermal dcp 0` took the lane from
# 1000 -> 2500 and nothing re-applied 1000 for 21 s, so zeroing is a partial
# unlock, not a hand-back. Snapshot each lane the first time we take it over and
# write those values back on release. The file survives a daemon restart - the
# panel kills this script mid-session on a toggle, and a killed daemon would
# otherwise leave max_iin pinned with no memory of what it replaced.
IFACE_SAVED=$ST/iface
iface_snapshot() {
  [ -s "$IFACE_SAVED" ] && return
  s=""
  for l in $iface_lanes; do
    v=$(grep -m1 "^$l " "$IFACE/iin_limit" 2>/dev/null)
    v=${v#"$l "}
    [ -n "$v" ] && [ "$v" != 0 ] && [ "$v" -lt "$max_iin" ] 2>/dev/null && \
      s="$s $l=$v"
  done
  [ -n "$s" ] && echo $s > "$IFACE_SAVED"
}

do_release() {
  for p in $(cat "$IFACE_SAVED" 2>/dev/null); do
    echo "thermal ${p%%=*} ${p##*=}" > "$IFACE/iin_limit" 2>/dev/null
  done
  rm -f "$IFACE_SAVED"
  dciin_release
  pd_release
}

# PD push state: snapshot the IC values we replace and hand them back on
# release or on the temperature guard. The OS re-asserts its own values within
# ~10s anyway; the snapshot just makes a pause/unplug hand-back immediate.
PD_SAVED=$ST/pd
pd_snapshot() {
  [ -s "$PD_SAVED" ] && return
  s=""
  v=$(cat "$AICR" 2>/dev/null)
  [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && [ "$v" -lt "$aicr_target" ] 2>/dev/null && s="$s aicr=$v"
  v=$(cat "$ICHRG" 2>/dev/null)
  [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && [ "$v" -lt "$ichg_target" ] 2>/dev/null && s="$s ichg=$v"
  [ -n "$s" ] && echo $s > "$PD_SAVED"
}

pd_release() {
  for p in $(cat "$PD_SAVED" 2>/dev/null); do
    case ${p%%=*} in
      aicr) n=$AICR ;;
      ichg) n=$ICHRG ;;
      *) continue ;;
    esac
    [ "$(cat "$n" 2>/dev/null)" = "${p##*=}" ] || echo "${p##*=}" > "$n" 2>/dev/null
  done
  rm -f "$PD_SAVED"
}

unlock_pd_limits() {
  [ "$aicr_unlock" = "1" ] || [ "$ichg_unlock" = "1" ] || return 0
  # only while actually charging: pushing ICHG on Full can float/restart the pack
  [ "$status" = "Charging" ] || return 0
  if [ -n "$temp" ] && [ "$pd_temp_guard" -gt 0 ] 2>/dev/null && \
     [ "$temp" -ge "$pd_temp_guard" ] 2>/dev/null; then
    pd_release
    return 0
  fi
  # a guard release drops the snapshot; re-take it before pushing again so a
  # later hand-back returns to whatever the OS settled on while we were away
  pd_snapshot
  if [ "$aicr_unlock" = "1" ]; then
    v=$(cat "$AICR" 2>/dev/null)
    [ "$v" = "$aicr_target" ] || echo "$aicr_target" > "$AICR" 2>/dev/null
  fi
  if [ "$ichg_unlock" = "1" ]; then
    v=$(cat "$ICHRG" 2>/dev/null)
    [ "$v" = "$ichg_target" ] || echo "$ichg_target" > "$ICHRG" 2>/dev/null
  fi
}

# Per-device iin_thermal fight for stock direct-charge heads. Both this node and
# interface/iin_limit read back the same storage (sc_get_iin_limit reads
# sc_di+0x143c, exactly what sc_set_iin_limit writes), and the vendor writes it
# here directly - so the fight must happen here, last-writer-wins. Every write
# above the temp_para row is clamped AND logs one kernel error line, so a blind
# per-poll re-assert is not an option: track what our last write landed
# ($DCIIN_EXP) and re-assert only when the value drops below it. If the value
# rose above it (vendor relaxed after a temp drop), adopt the new value.
DCIIN_EXP=$ST/dciin_exp
DCIIN_SAVED=$ST/dciin_saved
dciin_push() {
  [ "$dc_iin_unlock" = "1" ] || return 0
  [ "$status" = "Charging" ] || return 0
  for _m in $(echo "$dc_iin_devs" | tr ',' ' '); do
    _n=$DC/direct_charger_$_m/iin_thermal
    [ -w "$_n" ] || continue
    _v=$(cat "$_n" 2>/dev/null)
    [ -n "$_v" ] || continue
    _e=$(awk -v k="$_m" '$1==k{print $2; exit}' "$DCIIN_EXP" 2>/dev/null)
    [ -n "$_e" ] || _e=$max_iin
    if [ "$_v" -ge "$_e" ] 2>/dev/null; then
      # vendor raised it at/above our landed value: adopt, nothing to fight
      if [ "$_v" -gt "$_e" ] 2>/dev/null; then
        awk -v k="$_m" '$1!=k' "$DCIIN_EXP" 2>/dev/null > "$DCIIN_EXP.t"
        echo "$_m $_v" >> "$DCIIN_EXP.t"
        mv "$DCIIN_EXP.t" "$DCIIN_EXP"
      fi
      continue
    fi
    grep -q "^$_m " "$DCIIN_SAVED" 2>/dev/null || echo "$_m $_v" >> "$DCIIN_SAVED"
    echo "$max_iin" > "$_n" 2>/dev/null || continue
    _nv=$(cat "$_n" 2>/dev/null)
    [ -n "$_nv" ] || continue
    awk -v k="$_m" '$1!=k' "$DCIIN_EXP" 2>/dev/null > "$DCIIN_EXP.t"
    echo "$_m $_nv" >> "$DCIIN_EXP.t"
    mv "$DCIIN_EXP.t" "$DCIIN_EXP"
    fight=$((fight + 1))
  done
}

dciin_release() {
  if [ -s "$DCIIN_SAVED" ]; then
    while read -r _m _v; do
      [ -n "$_m" ] && [ -n "$_v" ] && \
        echo "$_v" > "$DC/direct_charger_$_m/iin_thermal" 2>/dev/null
    done < "$DCIIN_SAVED"
  fi
  rm -f "$DCIIN_SAVED" "$DCIIN_EXP" "$DCIIN_EXP.t"
}

poke_protocols() {
  # best-effort; on many builds enable_charger is a read-only view kept by the
  # charge FW (values then follow the attached adapter). On this build all four
  # lines are refused with [E/power_if] unable to parse input:<line> (measured
  # 2026-11-03/04: 11 such lines = one plug's worth x2), so the poke costs a
  # kernel error per line but only once per plug - unlike the old per-cycle
  # iin_thermal writes it is not a noise source.
  echo "pd 1" > "$IFACE/enable_charger" 2>/dev/null
  echo "hvc 1" > "$IFACE/enable_charger" 2>/dev/null
  echo "hsc 1" > "$IFACE/enable_charger" 2>/dev/null
  echo "sc 1" > "$IFACE/enable_charger" 2>/dev/null
  echo 1 > "$IFACE/charge_turbo_enable" 2>/dev/null
}

dump_arbitration() {
  # protocol arbitration evidence after a plug event (fills in with real adapters)
  {
    echo "=== plug $(date) adapter=$(cat /sys/class/hw_power/adapter/adapter_type 2>/dev/null) support_mode=$(cat /sys/class/hw_power/adapter/support_mode 2>/dev/null)"
    echo "    max_volt=$(cat /sys/class/hw_power/adapter/max_volt 2>/dev/null) max_cur=$(cat /sys/class/hw_power/adapter/max_cur 2>/dev/null) fwver=$(cat /sys/class/hw_power/adapter/fwver 2>/dev/null)"
    dmesg | grep -E "adapter_prot_arbitration|protocol_info|chg_adapter|ufcs|pd_max_watt|pe4" | tail -30
  } >> "$LOG" 2>&1
}

# single instance (validate the pid actually is our daemon, pidfile survives reboot)
if [ -f "$PIDF" ]; then
  old=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$old" ] && [ -d "/proc/$old" ] && grep -q "honor_charge_unlock/service.sh" "/proc/$old/cmdline" 2>/dev/null; then
    exit 0
  fi
  rm -f "$PIDF"
fi
echo $$ > "$PIDF"

# Leave the cgroup we may have been born in. A daemon started from a root shell
# that the KernelSU APP spawned inherits that app's per-pid group
# (/sys/fs/cgroup/apps/uid_<ksu>/pid_<app>), and system_server FREEZES it
# (cgroup.freeze=1) the moment the app goes cached: the daemon stops mid-`sleep`,
# do_unlock never runs again, and nothing is logged - measured 2026-11-02: one
# `sleep 10` child alive 10h52m with utime/stime frozen, whole watcher tree stuck
# in the same group, while a collector sitting in 0::/ kept ticking untouched.
# Reparenting to init does NOT change the cgroup, so the move must be explicit -
# and before any watcher forks, since children inherit and it is the main loop's
# own `sleep` whose freeze deadlocks the loop.
cgroup_now() { awk -F: '$1=="0"{print $3}' /proc/$$/cgroup 2>/dev/null; }
cgroup_escape() {
  for g in /sys/fs/cgroup/cgroup.procs /sys/fs/cgroup/system/cgroup.procs; do
    [ -w "$g" ] || continue
    echo $$ > "$g" 2>/dev/null || continue
    # $$ not /proc/self: this runs in a command substitution, and the subshell
    # keeps the OLD cgroup after the parent is moved.
    case "$(cgroup_now)" in ""|*/apps/*) : ;; *) printf '%s\n' "$g"; return ;; esac
  done
  printf 'none\n'
}
CGFROM=$(cgroup_now)
CGTO=$(cgroup_escape)
if [ "$CGTO" = "none" ]; then
  log "cgroup: still in ${CGFROM:-?} (escape failed - the app can freeze this daemon)"
else
  case $CGFROM in */apps/*) log "cgroup: moved out of $CGFROM -> $CGTO (app groups get frozen when the app is cached)" ;; esac
fi


# ---------- QR scan fix (v1.9.8): runtime switch handling ----------
# post-fs-data already applied the mount for the cold-boot case; this branch
# runs BEFORE the boot wait so a panel toggle (webui_ctl restarts the daemon)
# takes effect immediately: qr_fix=1 (re)mounts, qr_fix=0 unmounts. Idempotent.
QR_TGT=/odm/etc/camera/airaw/facemaskconfig.xml
QR_STF=$ST/qr
if [ "$qr_fix" = "1" ] && [ -f "$MODDIR/qrfix/facemaskconfig.xml" ] && [ -f "$QR_TGT" ]; then
  # the HAL runs as u:r:mtk_hal_camera and is denied adb_data_file; the module
  # file sits under /data/adb, so relabel it to match the stock target. chcon on
  # the source inode also applies to an existing bind mount of that inode.
  chcon u:object_r:vendor_configs_file:s0 "$MODDIR/qrfix/facemaskconfig.xml" 2>/dev/null
  if ! grep -aq "facemaskconfig.xml" /proc/mounts 2>/dev/null; then
    mount --bind "$MODDIR/qrfix/facemaskconfig.xml" "$QR_TGT" 2>/dev/null
  fi
  if grep -aq "facemaskconfig.xml" /proc/mounts 2>/dev/null; then
    echo "on" > "$QR_STF" 2>/dev/null
  else
    echo "mount-failed" > "$QR_STF" 2>/dev/null
  fi
else
  umount "$QR_TGT" 2>/dev/null
  echo "off" > "$QR_STF" 2>/dev/null
fi

# ---------- eSIM EID guard (v2.2.2): runtime switch handling ----------
# post-fs-data already applied the mount for the cold-boot case; this branch runs
# BEFORE the boot wait so a panel toggle (webui_ctl restarts the daemon) takes
# effect without a reboot. That works because nothing maps the lib until the first
# SIM state change - once com.android.phone has loaded it, the already-mapped
# copy stays, and only the next boot picks the new one. Idempotent: apply.sh
# unmounts first and regenerates from the factory lib every call.
sh "$MODDIR/eidfix/apply.sh" "$MODDIR" "$eid_guard"

# ---------- SmartAE exposure knob (v1.9.9): numeric, bind-mounted ----------
# Regenerated from the pristine module copy on every daemon start, so the knob
# is stateless: any value (including 0 = factory) is reachable without reflashing
# or tracking previous state. The camera HAL re-reads tuning per open, so the
# value lands when the camera is reopened - no reboot, no daemon-loop polling.
# Content check (not /proc/mounts) decides success: EROFS binds surface there as
# the underlying dm-* block device, so path matching is unreliable on this ROM.
CAM_ORIG=$MODDIR/camfix/SmartAE_back_orig.xml
CAM_TGT=/odm/etc/camera/smartae/back/SmartAE.xml
CAM_DIR=$ST/camfix
CAM_GEN=$CAM_DIR/SmartAE_back.xml
CAM_STF=$ST/cam
cam_target=${smartae_target:-185}
case "$cam_target" in ''|*[!0-9]*) cam_target=185 ;; esac
if [ "$cam_target" -gt 0 ] && [ -f "$CAM_ORIG" ] && [ -f "$CAM_TGT" ]; then
  mkdir -p "$CAM_DIR" 2>/dev/null
  sed "s|<Target>[0-9]*</Target>|<Target>$cam_target</Target>|g" "$CAM_ORIG" > "$CAM_GEN.new" 2>/dev/null
  n=$(grep -c "<Target>$cam_target</Target>" "$CAM_GEN.new" 2>/dev/null)
  if [ "${n:-0}" -eq 3 ] && [ -s "$CAM_GEN.new" ]; then
    mv "$CAM_GEN.new" "$CAM_GEN"; chmod 644 "$CAM_GEN" 2>/dev/null
    # HAL domain cannot read adb_data_file; the stock target is vendor_configs_file
    chcon u:object_r:vendor_configs_file:s0 "$CAM_GEN" 2>/dev/null
    if ! grep -q "<Target>$cam_target</Target>" "$CAM_TGT" 2>/dev/null; then
      umount "$CAM_TGT" 2>/dev/null
      mount --bind "$CAM_GEN" "$CAM_TGT" 2>/dev/null
    fi
  else
    rm -f "$CAM_GEN.new"
  fi
  if grep -q "<Target>$cam_target</Target>" "$CAM_TGT" 2>/dev/null; then
    echo "on $cam_target" > "$CAM_STF" 2>/dev/null
  else
    echo "mount-failed $cam_target" > "$CAM_STF" 2>/dev/null
  fi
else
  umount "$CAM_TGT" 2>/dev/null
  echo "off" > "$CAM_STF" 2>/dev/null
fi

# ---------- Rear-main sharpen knob (v2.2.0): EE table in the ISP tuning DB ----------
# The real rear-main sharpener is the MTK ISP EE stage, not the HDR+ hdrp_mc.xml
# tags the v2.0.0 knob edited - that route was disproven on-device (its A/B showed
# no change, and those tags have no runtime reader in this pipeline). Disassembly
# of libispfeature_mtkcam.v4l2.so shows Smooth_EE reading H1_GN/H2_GN/H3_GN (0x10
# bits0-4 / bits8-12, 0x12 bits0-4) and MASTER_GN_POS/NEG (0x40/0x41) out of
# isp_ee_Param, interpolating them per ISO block and packing them for EECNR.
# The rows live in the single-row `ee` BLOB of
# /odm/.../calvrns_m010_ldy/ISP_param.db (1562 x 160 B). ISP_info.db links every
# capture FeatureModule (22 Capture_default/LPNR=73, 23=6, 29 cfnr=110, AIISP=137)
# to NVRAM group 'EE', so one ee column covers normal/LPNR/MFNR/AIISP captures.
# This ROM has no sqlite3, so tiers ship as 4096-byte page patches: the stock DB
# is sha256-pinned, copied to $ST/camfix, the 63 changed pages are written
# with dd, relabelled vendor_file (the stock label) and bind-mounted. Off = umount.
# Each tier scales H1_GN and MASTER_GN_POS/NEG per ISO block, so the factory
# relative strength between blocks is kept (a flat value would over-sharpen the
# blocks the tuning already treats gently). H1 is capped at its 5-bit field limit
# 31; MASTER_GN is an unmasked u8. H2/H3 stay at factory (H2 is 0 in every block).
#   level 0 = off (factory)   1 = x1.25   2 = x1.5 (default, on-device A/B)
#   3 = x2.0 (unmeasured)     4 = x2.5 (unmeasured)
# Cost grows with the level: the blocks that sharpen hardest also amplify ISO
# noise/grain. Same delivery as the other camfix knobs: no partition write,
# dm-verity untouched, and the HAL re-reads the DB per camera open, so a daemon
# restart lands the new tier on the next camera open (no reboot).
SHP_TGT=/odm/bin/crossbuild/DataSet/SQLiteModule/db/tuning_DB/calvrns_m010_ldy/ISP_param.db
SHP_STOCK_SHA=15a18414c0c7ce5d648bf341473059da996b46426ff63ca590ad8d31c441f79b
SHP_PATCH=$MODDIR/ee_patch
SHP_DIR=$ST/camfix
SHP_STF=$ST/shp
shp_lv=${sharpen_level:-2}
case "$shp_lv" in ''|*[!0-9]*) shp_lv=2 ;; esac
[ "$shp_lv" -gt 4 ] && shp_lv=4
# retire the v2.0.0 hdrp_mc.xml binds (ineffective; harmless if absent)
for shp_b in /odm/etc/camera/hdrplite /odm/etc/camera/rawhdr; do
  for shp_d in $(grep '_hpb_P=' "$shp_b/device.config" 2>/dev/null | sed 's|.*=||' | tr -d '\r'); do
    umount "${shp_d}hdrp_mc.xml" 2>/dev/null
  done
done
rm -f "$SHP_DIR"/hdrp_mc_*.xml 2>/dev/null
# unmount first: the sha gate must read the factory DB, not a previous tier
umount "$SHP_TGT" 2>/dev/null
if [ "$shp_lv" -ge 1 ] && [ -f "$SHP_TGT" ] && [ -f "$SHP_PATCH/lv$shp_lv.bin" ] \
   && [ -f "$SHP_PATCH/lv$shp_lv.txt" ] && [ -f "$SHP_PATCH/lv$shp_lv.sha" ]; then
  mkdir -p "$SHP_DIR" 2>/dev/null
  SHP_GEN=$SHP_DIR/ISP_param_lv$shp_lv.db
  if [ "$(sha256sum "$SHP_TGT" 2>/dev/null | cut -d' ' -f1)" = "$SHP_STOCK_SHA" ]; then
    cp "$SHP_TGT" "$SHP_GEN.new" 2>/dev/null
    shp_rc=0
    while read -r shp_pg shp_of; do
      dd if="$SHP_PATCH/lv$shp_lv.bin" of="$SHP_GEN.new" bs=4096 \
         skip="$shp_of" seek="$shp_pg" count=1 conv=notrunc 2>/dev/null || shp_rc=1
    done < "$SHP_PATCH/lv$shp_lv.txt"
    if [ "$shp_rc" = "0" ] && [ "$(sha256sum "$SHP_GEN.new" 2>/dev/null | cut -d' ' -f1)" = "$(cat "$SHP_PATCH/lv$shp_lv.sha" 2>/dev/null)" ]; then
      mv "$SHP_GEN.new" "$SHP_GEN" 2>/dev/null
      chmod 644 "$SHP_GEN" 2>/dev/null
      # the factory DB is vendor_file (not vendor_configs_file) and the HAL
      # domain cannot read adb_data_file, so match the stock label exactly
      chcon u:object_r:vendor_file:s0 "$SHP_GEN" 2>/dev/null
      mount --bind "$SHP_GEN" "$SHP_TGT" 2>/dev/null
      # content check through the /odm path: an unmounted target still reads the
      # factory EE blob, so cmp fails instead of reporting a false "on"
      if cmp -s "$SHP_GEN" "$SHP_TGT"; then
        echo "on $shp_lv" > "$SHP_STF" 2>/dev/null
      else
        echo "mount-failed $shp_lv" > "$SHP_STF" 2>/dev/null
      fi
    else
      rm -f "$SHP_GEN.new" 2>/dev/null
      echo "patch-failed $shp_lv" > "$SHP_STF" 2>/dev/null
    fi
  else
    echo "unsupported $shp_lv" > "$SHP_STF" 2>/dev/null
  fi
else
  rm -f "$SHP_DIR"/ISP_param_lv*.db 2>/dev/null
  echo "off" > "$SHP_STF" 2>/dev/null
fi

# ---------- Front beauty knob (v2.0.1): numeric, two bind-mounts ----------
# Same stateless delivery as the other camfix knobs: umount so the transform
# always reads the pristine module copy, awk-scale the whitelisted effect curves,
# bind-mount, then prove the mount took by reading the <!--btyN--> marker back
# THROUGH the /odm path (content check, not /proc/mounts - see the SmartAE note).
# The awk's row count is a schema fingerprint (this file matches 192 effect rows);
# mounting only proceeds past the threshold, so a ROM that relaid-out these arrays
# leaves the tuning untouched instead of half-mangled. Front camera only - the
# back modules the same engine reads are never bound.
BTY_AWK=$MODDIR/camfix/beauty.awk
BTY_DIR=$ST/camfix
BTY_STF=$ST/bty
bty_cut=${beauty_cut:-30}
case "$bty_cut" in ''|*[!0-9]*) bty_cut=30 ;; esac
[ "$bty_cut" -gt 90 ] && bty_cut=90
# The engine picks the file by styleMode (libsit_refine_engine.so, the
# csel at 0x98d978 over the compares at 0x98d960): styleMode 0 (拍照页) and
# 73 read hwbeauty_params_lp.xml, every other style (人像 etc.) reads
# hwbeauty_params.xml. Binding only the second file left photo-page selfies
# untouched, so both are bound with the same transform.
# That routing was confirmed on-device the blunt way: bind-mount an empty file
# over _lp.xml only, restart the camera, and the photo page loses all smoothing
# (spots/stubble visible) while 人像 in the same process keeps its cream skin -
# so the photo page really does read _lp.xml and nothing else does. Intensity
# deltas are NOT a usable proof: single-shot skin texture varies more between
# two frames of the same setting than between cut=0 and cut=90.
bty_one() {
  b_orig=$1; b_tgt=$2; b_gen=$3
  [ -f "$b_orig" ] && [ -f "$b_tgt" ] && [ -f "$BTY_AWK" ] || return 1
  # the two stock files disagree on their final-line newline (params.xml has
  # none, _lp.xml does); tell awk per file so cut stays a byte-accurate
  # round-trip instead of adding or dropping a byte
  bty_eof=1; [ -n "$(tail -c1 "$b_orig" 2>/dev/null)" ] && bty_eof=0
  umount "$b_tgt" 2>/dev/null
  awk -v cut="$bty_cut" -v eofnl="$bty_eof" -v cnt="$b_gen.cnt" -f "$BTY_AWK" "$b_orig" > "$b_gen.new" 2>/dev/null
  nb=$(cat "$b_gen.cnt" 2>/dev/null); rm -f "$b_gen.cnt" 2>/dev/null
  case "$nb" in ''|*[!0-9]*) nb=0 ;; esac
  if [ -s "$b_gen.new" ] && [ "$nb" -ge 100 ]; then
    mv "$b_gen.new" "$b_gen"; chmod 644 "$b_gen" 2>/dev/null
    # same SELinux gate as the other camfix knobs: adb_data_file is denied to
    # u:r:mtk_hal_camera, the stock hwbeauty file is vendor_configs_file
    chcon u:object_r:vendor_configs_file:s0 "$b_gen" 2>/dev/null
    mount --bind "$b_gen" "$b_tgt" 2>/dev/null
  else
    rm -f "$b_gen.new"
  fi
  grep -aq "bty$bty_cut" "$b_tgt" 2>/dev/null
}
bty_total=2
if [ "$bty_cut" -gt 0 ]; then
  mkdir -p "$BTY_DIR" 2>/dev/null
  bty_mounted=0
  bty_one "$MODDIR/camfix/hwbeauty_front_orig.xml" /odm/etc/camera/hwbeauty/front/hwbeauty_params.xml "$BTY_DIR/hwbeauty_front.xml" && bty_mounted=$((bty_mounted+1))
  bty_one "$MODDIR/camfix/hwbeauty_front_lp_orig.xml" /odm/etc/camera/hwbeauty/front/hwbeauty_params_lp.xml "$BTY_DIR/hwbeauty_front_lp.xml" && bty_mounted=$((bty_mounted+1))
  if [ "$bty_mounted" -ge 1 ]; then
    echo "on $bty_cut $bty_mounted/$bty_total" > "$BTY_STF" 2>/dev/null
  else
    echo "mount-failed $bty_cut 0/$bty_total" > "$BTY_STF" 2>/dev/null
  fi
else
  umount /odm/etc/camera/hwbeauty/front/hwbeauty_params.xml 2>/dev/null
  umount /odm/etc/camera/hwbeauty/front/hwbeauty_params_lp.xml 2>/dev/null
  echo "off" > "$BTY_STF" 2>/dev/null
fi

# v2.0.3 one-time upgrade cleanup: the removed wide_ae_target knob left a bind-mount
# on the orphaned back/wide/SmartAE.xml from earlier builds. Unmount it so /odm reads
# stay honest while A/B testing the night toggle (idempotent, cheap, once per start).
if grep -q ' /odm/etc/camera/smartae/back/wide/SmartAE.xml ' /proc/mounts 2>/dev/null; then
  umount /odm/etc/camera/smartae/back/wide/SmartAE.xml 2>/dev/null
fi
rm -f $ST/wae $ST/camfix/SmartAE_wide.xml 2>/dev/null

# v2.0.4 one-time upgrade cleanup: the removed night_ev knob (v2.0.3) left a
# bind-mount on supernight/config.xml from earlier builds. Unmount it so /odm
# reads stay honest while A/B testing the gate toggle (idempotent, once per start).
if grep -q ' /odm/etc/camera/supernight/config.xml ' /proc/mounts 2>/dev/null; then
  umount /odm/etc/camera/supernight/config.xml 2>/dev/null
fi
rm -f $ST/nev $ST/camfix/supernight_config.xml 2>/dev/null

# v2.0.5 one-time upgrade cleanup: the removed wide_night_gate knob (v2.0.4) left
# a bind-mount on featureConfig/dynamic_parameter.xml from that build. That A/B
# mounted a file with no proven runtime reader, so it cannot back any conclusion
# about the gate; the knob stays retired. Unmount it so /odm reads stay honest
# (idempotent, cheap, once per start).
if grep -q ' /odm/etc/camera/featureConfig/dynamic_parameter.xml ' /proc/mounts 2>/dev/null; then
  umount /odm/etc/camera/featureConfig/dynamic_parameter.xml 2>/dev/null
fi
rm -f $ST/wng $ST/camfix/dynamic_parameter.xml 2>/dev/null

# v2.0.7 payload cleanup: uw_gain was removed after that AE-table route was
# disproven on-device (raising the 311 curve blindly triggered a P1Node
# TimeBomb on dark scenes). Drop the payload and stale state from v2.0.6
# installs. Do NOT unmount the AE DB here: the v2.1.0 block below owns that
# mount now, and this code runs on every daemon start (webui_ctl restarts the
# daemon after every panel write), so an unmount here would silently revert
# the uw_exp_ms/uw_iso_gain knobs.
rm -f $ST/uwg $ST/uwg.mnt \
      "$MODDIR/camfix/uw_gain_blobs.bin" 2>/dev/null

# ---------- Ultra-wide low-light exposure knob (v2.1.0) ----------
# Mechanism/measurements live in the config template above. Both payloads are
# rebuilt from the factory files on every daemon start; the factory sha256 is
# the gate, so a different ROM build is left untouched instead of being
# half-patched. Delivery is bind-mount only (no partition write, dm-verity
# untouched), and "off" is a plain umount.
UWA_DB_TGT=/odm/bin/crossbuild/DataSet/SQLiteModule/db/ae/ParameterDB_ae.db
UWA_SO_TGT=/vendor/lib64/mt6993/libmtkcam_metastore.so
# AE pline 311 stock sha per ROM. MagicOS 11 (11.0.0.110) rebuilt the DB but the
# pline 311 layout is byte-identical at the same offsets (eMax@4265560=200000,
# iso@4265568=72000, 17 anchors @4265296 - verified on the OS11 factory /odm),
# so both pins share one patch path. metastore.so is unchanged across the two
# ROMs (same sha), hence a single UWA_SO_SHA.
UWA_DB_SHA=8e271ec39bf5bba14fa26e17bd0862becedb63ccf3cee8cc5cd210328b9a3732
UWA_DB_SHA11=8e2b793d96ee384a1e346f6c2cc8ec052cbe462f0be18ec8879b7fcb0a5336fa
UWA_SO_SHA=8e593affebc3e9ce6f15ba041f75ac7204993d6d10d10f041cf961f517b7937f
UWA_DB_BASE=4265296
UWA_DB_EMAX=4265560
UWA_DB_ISO=4265568
UWA_SO_OFF1=1335656
UWA_DIR=$ST/camfix
UWA_DB_GEN=$UWA_DIR/uw_ae.db
UWA_SO_GEN=$UWA_DIR/uw_metastore.so
UWA_STF=$ST/uwa
uw_exp_ms=${uw_exp_ms:-910}
case "$uw_exp_ms" in ''|*[!0-9]*) uw_exp_ms=910 ;; esac
if [ "$uw_exp_ms" -gt 0 ]; then
  [ "$uw_exp_ms" -lt 150 ] && uw_exp_ms=150
  [ "$uw_exp_ms" -gt 999 ] && uw_exp_ms=999
fi
uw_iso_gain=${uw_iso_gain:-100}
case "$uw_iso_gain" in ''|*[!0-9]*) uw_iso_gain=100 ;; esac
[ "$uw_iso_gain" -lt 100 ] && uw_iso_gain=100
[ "$uw_iso_gain" -gt 250 ] && uw_iso_gain=250
# stage target fps to the smallest drop that still allows the requested
# exposure (stock 5 = 199.954ms cap, 2 = 499.954ms, 1 = 999.954ms)
if [ "$uw_exp_ms" -eq 0 ] || [ "$uw_exp_ms" -le 199 ]; then
  uw_fps=5
elif [ "$uw_exp_ms" -le 499 ]; then
  uw_fps=2
else
  uw_fps=1
fi
uw_rd32() { od -An -tu4 -j "$2" -N4 "$1" 2>/dev/null | tr -d ' \n'; }
uw_wr32() {  # file offset value: little-endian bytes -> dd (NUL-safe)
  uw_b0=$(($3 & 255)); uw_b1=$((($3 >> 8) & 255))
  uw_b2=$((($3 >> 16) & 255)); uw_b3=$((($3 >> 24) & 255))
  uw_o0=$(printf '%03o' $uw_b0); uw_o1=$(printf '%03o' $uw_b1)
  uw_o2=$(printf '%03o' $uw_b2); uw_o3=$(printf '%03o' $uw_b3)
  printf "\\$uw_o0\\$uw_o1\\$uw_o2\\$uw_o3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}
uw_cur_exp=""; uw_cur_iso=""; uw_cur_fps=0
if [ -f "$UWA_DB_TGT" ]; then
  uw_v=$(uw_rd32 "$UWA_DB_TGT" "$UWA_DB_EMAX")
  case "$uw_v" in ''|*[!0-9]*) ;; *) uw_cur_exp=$((uw_v / 1000)) ;; esac
  uw_v=$(uw_rd32 "$UWA_DB_TGT" "$UWA_DB_ISO")
  case "$uw_v" in ''|*[!0-9]*) ;; *) uw_cur_iso=$((uw_v * 100 / 72000)) ;; esac
fi
if [ -f "$UWA_SO_TGT" ]; then
  uw_w=$(od -An -tx4 -j "$UWA_SO_OFF1" -N4 "$UWA_SO_TGT" 2>/dev/null | tr -d ' \n')
  case "$uw_w" in
    528000a8|528000A8) uw_cur_fps=5 ;;
    52800048) uw_cur_fps=2 ;;
    52800028) uw_cur_fps=1 ;;
  esac
fi
uw_new="off"
[ "$uw_exp_ms" -gt 0 ] && uw_new="on exp=$uw_exp_ms iso=$uw_iso_gain fps=$uw_fps"
uw_match=0
if [ "$uw_exp_ms" -eq 0 ]; then
  [ "$uw_cur_exp" = "200" ] && [ "$uw_cur_iso" = "100" ] && \
    [ "$uw_cur_fps" = "5" ] && uw_match=1
else
  [ "$uw_cur_exp" = "$uw_exp_ms" ] && [ "$uw_cur_iso" = "$uw_iso_gain" ] && \
    [ "$uw_cur_fps" = "$uw_fps" ] && uw_match=1
fi
uw_applied=0
if [ "$uw_match" = "0" ]; then
  # camerahalserver maps the metastore .so into memory, so a mount swap is not
  # visible to a running HAL. Kill it before touching the mounts, then kill
  # again after the bind (init may respawn it in the gap); the camera app is
  # closed while the WebUI is in use, and the next open loads the new mapping.
  uw_pid=$(pidof camerahalserver 2>/dev/null); uw_pid=${uw_pid%% *}
  [ -n "$uw_pid" ] && kill -TERM "$uw_pid" 2>/dev/null
  sleep 0.5
  if grep -qF " $UWA_DB_TGT " /proc/mounts 2>/dev/null; then
    umount "$UWA_DB_TGT" 2>/dev/null || umount -l "$UWA_DB_TGT" 2>/dev/null
  fi
  if grep -qF " $UWA_SO_TGT " /proc/mounts 2>/dev/null; then
    umount "$UWA_SO_TGT" 2>/dev/null || umount -l "$UWA_SO_TGT" 2>/dev/null
  fi
  uw_db_ok=0; uw_so_ok=0
  uw_s=$(sha256sum "$UWA_DB_TGT" 2>/dev/null | cut -d' ' -f1)
  case "$uw_s" in "$UWA_DB_SHA"|"$UWA_DB_SHA11") uw_db_ok=1 ;; esac
  uw_s=$(sha256sum "$UWA_SO_TGT" 2>/dev/null | cut -d' ' -f1)
  [ "$uw_s" = "$UWA_SO_SHA" ] && uw_so_ok=1
  if [ "$uw_db_ok" != "1" ] || [ "$uw_so_ok" != "1" ]; then
    # different ROM build: factory files stay in place, report it in the panel
    uw_new="unsupported db=$uw_db_ok so=$uw_so_ok"
  elif [ "$uw_exp_ms" -eq 0 ]; then
    uw_new="off"
  else
    mkdir -p "$UWA_DIR" 2>/dev/null
    # --- AE pline 311: raise the darkest anchor's exposure ceiling ---
    cp -f "$UWA_DB_TGT" "$UWA_DB_GEN.new" 2>/dev/null
    uw_wr32 "$UWA_DB_GEN.new" "$UWA_DB_EMAX" $((uw_exp_ms * 1000))
    if [ "$uw_iso_gain" -ne 100 ]; then
      uw_i=0
      while [ "$uw_i" -lt 17 ]; do
        uw_o=$((UWA_DB_BASE + 8 + 16 * uw_i + 8))
        uw_mx=$(uw_rd32 "$UWA_DB_GEN.new" "$uw_o")
        uw_mn=$(uw_rd32 "$UWA_DB_GEN.new" $((uw_o + 4)))
        case "$uw_mx" in ''|*[!0-9]*) break ;; esac
        case "$uw_mn" in ''|*[!0-9]*) break ;; esac
        uw_wr32 "$UWA_DB_GEN.new" "$uw_o" $((uw_mx * uw_iso_gain / 100))
        uw_wr32 "$UWA_DB_GEN.new" $((uw_o + 4)) $((uw_mn * uw_iso_gain / 100))
        uw_i=$((uw_i + 1))
      done
    fi
    uw_chk_exp=$(uw_rd32 "$UWA_DB_GEN.new" "$UWA_DB_EMAX")
    uw_chk_iso=$(uw_rd32 "$UWA_DB_GEN.new" "$UWA_DB_ISO")
    if [ "$uw_chk_exp" = "$((uw_exp_ms * 1000))" ] && \
       [ "$uw_chk_iso" = "$((72000 * uw_iso_gain / 100))" ] && \
       [ -s "$UWA_DB_GEN.new" ]; then
      mv -f "$UWA_DB_GEN.new" "$UWA_DB_GEN"; chmod 644 "$UWA_DB_GEN" 2>/dev/null
      # the HAL cannot read adb_data_file; the factory AE DB is vendor_file
      chcon u:object_r:vendor_file:s0 "$UWA_DB_GEN" 2>/dev/null
      mount --bind "$UWA_DB_GEN" "$UWA_DB_TGT" 2>/dev/null
    else
      rm -f "$UWA_DB_GEN.new"
    fi
    # --- metastore: target fps 5 -> 2/1 (four `mov w8,#5` immediates) ---
    if [ "$uw_fps" != "5" ]; then
      # 0x52800008 | (fps << 5), as decimals to avoid hex-arithmetic quirks
      if [ "$uw_fps" = "2" ]; then uw_word=1384120392; else uw_word=1384120360; fi
      cp -f "$UWA_SO_TGT" "$UWA_SO_GEN.new" 2>/dev/null
      for uw_o in 1335656 1336748 1338224 1338600; do
        uw_wr32 "$UWA_SO_GEN.new" "$uw_o" "$uw_word"
      done
      uw_c=0
      for uw_o in 1335656 1336748 1338224 1338600; do
        uw_w=$(od -An -tx4 -j "$uw_o" -N4 "$UWA_SO_GEN.new" 2>/dev/null | tr -d ' \n')
        [ "$uw_w" = "$(printf '%x' $uw_word)" ] && uw_c=$((uw_c + 1))
      done
      if [ "$uw_c" = "4" ] && [ -s "$UWA_SO_GEN.new" ]; then
        mv -f "$UWA_SO_GEN.new" "$UWA_SO_GEN"; chmod 644 "$UWA_SO_GEN" 2>/dev/null
        # same label the factory lib has on the vendor partition
        chcon u:object_r:vendor_file:s0 "$UWA_SO_GEN" 2>/dev/null
        mount --bind "$UWA_SO_GEN" "$UWA_SO_TGT" 2>/dev/null
      else
        rm -f "$UWA_SO_GEN.new"
      fi
    fi
    # prove the mount by reading the values back THROUGH /odm and /vendor
    # (content check, not /proc/mounts)
    uw_e=$(uw_rd32 "$UWA_DB_TGT" "$UWA_DB_EMAX")
    uw_j=$(uw_rd32 "$UWA_DB_TGT" "$UWA_DB_ISO")
    uw_f=$(od -An -tx4 -j "$UWA_SO_OFF1" -N4 "$UWA_SO_TGT" 2>/dev/null | tr -d ' \n')
    uw_got_fps=0
    case "$uw_f" in
      528000a8|528000A8) uw_got_fps=5 ;;
      52800048) uw_got_fps=2 ;;
      52800028) uw_got_fps=1 ;;
    esac
    if [ "$uw_e" = "$((uw_exp_ms * 1000))" ] && \
       [ "$uw_j" = "$((72000 * uw_iso_gain / 100))" ] && \
       [ "$uw_got_fps" = "$uw_fps" ]; then
      uw_applied=1
    else
      uw_new="mount-failed exp=${uw_e:-?} iso=${uw_j:-?} fps=$uw_got_fps"
    fi
  fi
  # a HAL may have respawned between the first kill and the bind; kill once
  # more only when the mounts actually changed (or when turning the knob off)
  if [ "$uw_applied" = "1" ] || [ "$uw_exp_ms" -eq 0 ]; then
    uw_pid=$(pidof camerahalserver 2>/dev/null); uw_pid=${uw_pid%% *}
    [ -n "$uw_pid" ] && kill -TERM "$uw_pid" 2>/dev/null
  fi
fi
echo "$uw_new" > "$UWA_STF" 2>/dev/null
log "uw: $uw_new (was exp=$uw_cur_exp iso=$uw_cur_iso fps=$uw_cur_fps match=$uw_match)"

# ---------- third-party home (v2.3.0): undo the boot-window mask ----------
# post-fs-data masked ro.build.characteristics to "phone" before zygote so
# system_server's HwPackageManagerServiceUtils latches
# (IS_CHINA && characteristics in {default,tablet}) == false and reports
# android.software.home_screen as supported - the bit both the HOME role and the
# AntiMal launcher check key off (full chain in post-fs-data.sh). That value is a
# static final, so the mask only has to survive class-init; the prop itself must
# be back to stock BEFORE later classes read it, because DataUtils.IS_PHONE is a
# strict "default" test that gates the display-engine capsule receiver.
# post-fs-data already launched tph_restore.sh at the earliest possible moment;
# this is the fallback for the case where that pre-zygote child did not survive.
# tph_restore.sh is idempotent (.tph.done), waits for the package service with
# the native client, issues one has-feature query (proof + forced latch) and then
# restores. A switch flipped without a reboot only changes the next boot.
if [ "$thirdparty_home" = "1" ] && [ -f "$MODDIR/tph_restore.sh" ]; then
  ( sh "$MODDIR/tph_restore.sh" >/dev/null 2>&1 & )
  log "thirdparty_home: restore fallback started"
fi

# wait for boot
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 10

log "daemon started pid=$$"

# ---------- launch boost (v2.0, perfserv_freq QoS pin) ----------
# Start  : ActivityManager "Start proc <pid>:<pkg> ... for [next-]top-activity"
# End    : ActivityTaskManager "Displayed <pkg>" (first frame) or ms timeout
# Method : write min=max pins to /proc/powerhal_cpu_ctrl/perfserv_freq. That
#          proc write atomically replaces the per-cluster PM-QoS min/max vote
#          PAIR (slot->cluster: 0-3=policy0, 4-6=policy4, 7=policy7) and the
#          last writer owns the pair, so re-pinning at ~10-30Hz wins the race
#          against perfserv's own launch caps (p4<=3.0G / p7<=3.5G): the whole
#          window runs pinned at cluster max (4.21G super core included).
#          (v1.6 raised scaling_min_freq via sysfs instead: cpufreq clamps
#          sysfs-min into the QoS range, so it could never pass 3.5G.)
# Safety : Displayed releases early; epoch prevents stale restores; hard cap
#          launch_boost_ms<=5000; zero-fork fifo pacer for the renewal ticks.
NODE=/proc/powerhal_cpu_ctrl/perfserv_freq
FG_FIF=/data/local/tmp/.hcu_tick
SC_FIF=/data/local/tmp/.hcu_tick2
FG_FLAG=/data/local/tmp/.hcu_lb_active
LB_EPOCH=/data/local/tmp/.hcu_lb_epoch
FG_P0MAX=2700000; FG_P4MAX=3500000; FG_P7MAX=4210000; FG_PMIN=300000
rm -f $FG_FLAG 2>/dev/null   # stale flag would pause scroll clamp until next boost
[ "$launch_boost_ms" -gt 5000 ] 2>/dev/null && launch_boost_ms=5000
lb_boost_on() {
  echo 0 $FG_P0MAX $FG_P0MAX > $NODE 2>/dev/null
  echo 4 $FG_P4MAX $FG_P4MAX > $NODE 2>/dev/null
  echo 7 $FG_P7MAX $FG_P7MAX > $NODE 2>/dev/null
  : > $FG_FLAG 2>/dev/null
}
lb_boost_off() {
  echo 0 $FG_PMIN $FG_P0MAX > $NODE 2>/dev/null
  echo 4 $FG_PMIN $FG_P4MAX > $NODE 2>/dev/null
  echo 7 $FG_PMIN $FG_P7MAX > $NODE 2>/dev/null
  rm -f $FG_FLAG 2>/dev/null
}
fg_fifo() {  # $1 = fifo path; one long-sleep holder, readers use read -t (no fork)
  [ -p "$1" ] || { rm -f "$1"; mkfifo "$1" 2>/dev/null; }
  pgrep -f "sleep 99999999" >/dev/null 2>&1 || sleep 99999999 > "$1" 2>/dev/null &
}
lb_renew() {  # $1=myepoch: re-pin every 100ms until epoch moves or ticks run out
  n=$(( ${launch_boost_ms:-2000} / 100 ))
  while [ $n -gt 0 ]; do
    lb_boost_on
    read -t 0.1 x < "$FG_FIF" 2>/dev/null || :
    [ "$(cat $LB_EPOCH 2>/dev/null)" != "$1" ] && return
    n=$((n-1))
  done
  [ "$(cat $LB_EPOCH 2>/dev/null)" = "$1" ] && lb_boost_off
}
lb_watch() {
  fg_fifo "$FG_FIF"
  echo 0 > "$LB_EPOCH"
  logcat -v brief -s ActivityManager:I ActivityTaskManager:I 2>/dev/null | while read -r line; do
    case "$line" in
      *"Start proc "*for\ top-activity*|*"Start proc "*for\ next-top-activity*)
        n=$(( $(cat "$LB_EPOCH") + 1 )); echo "$n" > "$LB_EPOCH"
        lb_boost_on
        lb_renew "$n" &
        ;;
      Displayed\ *)
        n=$(( $(cat "$LB_EPOCH") + 1 )); echo "$n" > "$LB_EPOCH"
        lb_boost_off
        ;;
    esac
  done
}
if [ "$launch_boost" = "1" ]; then
  lb_watch &
  log "launch_boost watcher started (v2 perfserv_freq QoS pin)"
fi
# ---------- scroll cap (v2, QoS vote channel) ----------
# Touch = wakeup_sources event2 event_count deltas (real finger only; injected
# input is invisible to it). While touched (+hold ticks), re-write the policy4
# vote pair with max=scroll_cap at ~20Hz; perfserv's scroll economy writes lose
# the race (100% occupancy measured). Paused while a launch boost owns the pair
# (flag file), resumed after.
sc_watch() {
  [ -p "$SC_FIF" ] || { rm -f "$SC_FIF"; mkfifo "$SC_FIF" 2>/dev/null; }
  pgrep -f "sleep 99999998" >/dev/null 2>&1 || sleep 99999998 > "$SC_FIF" 2>/dev/null &
  last_ev=X; touch_t=-99; tick=0; mode=IDLE
  while :; do
    tick=$((tick+1))
    read -t 0.1 x < "$SC_FIF" 2>/dev/null || :
    if [ $((tick % 2)) -eq 0 ]; then
      ev=$(grep -m1 -s ^event2 /proc/wakeup_sources 2>/dev/null)
      case $ev in "$last_ev") ;; *) touch_t=$tick; last_ev=$ev ;; esac
    fi
    if [ -f "$FG_FLAG" ]; then mode=BOOST; continue; fi
    if [ $((tick - touch_t)) -lt ${scroll_hold_ticks:-4} ]; then
      echo 4 $FG_PMIN $scroll_cap > $NODE 2>/dev/null
      echo 4 $FG_PMIN $scroll_cap > $NODE 2>/dev/null
      mode=SCROLL
    elif [ "$mode" = SCROLL ]; then
      echo 4 $FG_PMIN $FG_P4MAX > $NODE 2>/dev/null
      mode=IDLE
    fi
  done
}
if [ "$scroll_cap" != "0" ] && [ -n "$scroll_cap" ]; then
  sc_watch &
  log "scroll_cap watcher started (v2 QoS cap=$scroll_cap)"
fi

# ---------- FCM keep-alive unlock (v1.9) ----------
# All calls are uid-1000 binder transactions on the "pgservice" service
# (PGManagerService, IPGManager AIDL):
#   tx12 setPgConfig(6 /*CONFIG_TYPE_GOOGLE_CTRL*/, 0, urls)
#        -> PGGoogleServicePolicy probes those URLs instead of google.com;
#           first HTTP 200 flips the whole ROM into "google connected" state
#           (wakelock filter off, no uid firewall, iAware grace maintained).
#   tx21 notifyGoogleKeepAlive("com.google.android.gms", true)
#        -> setPgShouldNotFreeze + immediate unfreeze of GMS processes.
# Root-only, no persistent processes, no LSP injection (broken on Honor).
FCM_STF=$ST/fcm
fcm_urls=$(printf '%s' "$fcm_probe_urls" | tr -d ' \t\r' | tr ',' ' ')
fcm_avail=1

fcm_assert() {
  [ "$fcm_avail" = "1" ] || return 2
  [ -n "$fcm_urls" ] || { echo "off no-urls" > "$FCM_STF" 2>/dev/null; return 1; }
  n=0
  for u in $fcm_urls; do n=$((n+1)); done
  args="i32 6 i32 0 i32 $n"
  for u in $fcm_urls; do args="$args s16 $u"; done
  out=$(su 1000 -c "service call pgservice 12 $args" 2>&1)
  case "$out" in
    *00000001*) st=ok ;;
    *"Can't find service"*|*"not found"*)
      fcm_avail=0; echo "nosvc" > "$FCM_STF" 2>/dev/null
      log "fcm: pgservice not available, fcm_unlock disabled this boot"
      return 2 ;;
    *) return 1 ;;   # PG not ready yet -> retry shortly
  esac
  if [ "$fcm_keepalive" = "1" ]; then
    su 1000 -c "service call pgservice 21 s16 com.google.android.gms i32 1" >/dev/null 2>&1
  fi
  if [ "$fcm_grace_keeper" = "1" ]; then
    # iAware reads this once per boot: disconn=0(conned-since-epoch), conn=1
    # -> grace period (default 7d, cloud key google_delaytime) always fresh
    [ "$(getprop persist.sys.iaware_google_conn)" != "0,1" ] && \
      setprop persist.sys.iaware_google_conn "0,1" 2>/dev/null
  fi
  if [ "$fcm_gms_on" = "1" ] && pm path com.google.android.gms >/dev/null 2>&1; then
    [ "$(settings get secure google_service_status 2>/dev/null)" != "1" ] && \
      settings put secure google_service_status 1 2>/dev/null
  fi
  echo "$st n=$n" > "$FCM_STF" 2>/dev/null
  log "fcm: probe urls injected ($n) + keepalive/grace/gms asserted"
  # verify the ACTUAL probe verdict (injection success != probe success);
  # async so the charge-reassert loop never stalls. Log volume evicts
  # hundreds of lines per second: anchor the dump at the assert timestamp
  # (-T); a line-count window (-t 300) had already rotated out by the
  # time we looked (8s later) on chatty builds.
  {
    ts=$(date '+%m-%d %H:%M:%S.000')
    sleep 8
    lc=$(logcat -d -T "$ts" -s PGGoogleServicePolicy:D 2>/dev/null)
    case "$lc" in
      *"connect google success"*) v="probe:ok" ;;
      *"connect google failed"*) v="probe:fail" ;;
      *) v="" ;;
    esac
    if [ -n "$v" ]; then
      echo "$st n=$n $v" > "$FCM_STF" 2>/dev/null
      log "fcm: probe verdict $v"
    fi
  } &
  return 0
}

fcm_last=0
fcm_boot_boost=5   # dense 60s re-asserts right after daemon start (PowerGenie re-push race)

# ---------- VPN lock (v1.9.3) ----------
# GMS's MCS network selector (chyq.k, GMS 26.32 code-level analysis) checks
# VpnTransportInfo.isBypassable() on the active network: if the VPN declares
# allowBypass, it unwraps the VPN and binds the underlying WiFi/Cell to reach
# mtalk.google.com directly (dead in CN). No GMS flag can disable that, but a
# SYSTEM lockdown does: "always-on VPN + block connections without VPN"
# overrides bypassable to false and netd deletes the underlying routes.
# Applied here as root through the vpn_management binder (IVpnManager):
#   tx15 setAlwaysOnVpnPackage(user 0, pkg, lockdown, allowlist [])
#        - returns true/false; a non-VPN package is a harmless no-op
#        - persists app+lockdown into Settings.Secure (saveAlwaysOnPackage)
#          -> scrubbed right after, so the lock lives in memory only and a
#        reboot never force-starts the VPN with its tunnel missing (blackout)
#   tx16/17 read back the package / lockdown flag (used to verify + to clean
#        up a lock left over from a daemon kill while the tunnel stayed up)
# Parcel layout via service(1): i32 userId, s16 pkg, i32 bool (1 byte read,
# realigned), i32 0 = empty allowlist; "i32 -1" writes a length of -1 which
# the server reads as pkg=null -> releases always-on AND lockdown.
VPN_STF=$ST/vpn
VPN_TX_SET=15
VPN_TX_LOCK=17
vpn_tx() { service call vpn_management "$@" 2>/dev/null; }
vpn_is_locked() { case "$(vpn_tx $VPN_TX_LOCK i32 0)" in *00000001*) return 0 ;; esac; return 1; }
vpn_apply() {  # $1 = connected VPN package
  out=$(vpn_tx $VPN_TX_SET i32 0 s16 "$1" i32 1 i32 0)
  case "$out" in
    *Result:*00000001*)
      # the server persisted app+lockdown into Settings.Secure; scrub it so
      # the lock lives in memory only (a reboot must never force-start the
      # VPN with no tunnel up - that is a total-connectivity lockdown trap)
      settings delete secure always_on_vpn_app 2>/dev/null
      settings delete secure always_on_vpn_lockdown 2>/dev/null
      return 0 ;;
  esac
  return 1
}
vpn_release() { vpn_tx $VPN_TX_SET i32 0 i32 -1 i32 0 i32 0 >/dev/null 2>&1; }
# a lockdown the user configured themselves in system Settings (settings keys
# non-empty) is THEIR config: never apply-scrub over it, never release it
vpn_user_cfg() { [ "$(settings get secure always_on_vpn_app 2>/dev/null)" != "null" ]; }
# The active tunnel's VpnTransportInfo.bypassable flag. The whole point of the
# lockdown is to stop GMS's MCS (chyq.k) from UNWRAPPING a bypassable VPN to
# reach mtalk directly. If the tunnel is ALREADY non-bypassable (bypassable=false)
# there is nothing to lock - MCS cannot unwrap it anyway. Worse, applying the
# lockdown to a manual VPN (startSession by the app, not a startService-able
# always-on service) makes system_server's Vpn.setAlwaysOnPackage ->
# startAlwaysOnVpn fail to bring up a real session, and the system ROLLS BACK the
# lock after the lockdown route-stripping has already killed the live session
# (proven on-device: apply -> 10ms "UnderlyingNW Switch to null" -> session
# UNKNOWN_ERROR -> system auto-releases). So: only apply when bypassable=true.
vpn_is_bypassable() {
  case "$(dumpsys vpn_management 2>/dev/null | grep -a 'VpnTransportInfo{' | head -n 1)" in
    *bypassable=true*) return 0 ;;
    *) return 1 ;;
  esac
}
vpn_lock_watch() {
  locked=0   # 0=none, 1=ephemeral lock applied by us, 2=user's own config
  echo idle > "$VPN_STF" 2>/dev/null
  while :; do
    if grep -q 'tun[0-9]' /proc/net/dev 2>/dev/null; then
      if [ "$locked" = "0" ]; then
        if vpn_user_cfg; then
          locked=2
          echo "locked (user-config)" > "$VPN_STF" 2>/dev/null
          log "vpn_lock: tunnel up under user-configured always-on, adopting"
        else
          # one dumpsys per poll; derive both the active package and the
          # tunnel's bypassable flag from it
          ds=$(dumpsys vpn_management 2>/dev/null)
          # [Legacy VPN] is the placeholder when no app VPN is connected; the
          # server rejects it as always-on anyway
          pkg=$(printf '%s\n' "$ds" | sed -n 's/^[[:space:]]*Active package name: //p' | head -n 1)
          case "$pkg" in
            ""|*"[Legacy VPN]"*) : ;;
            *)
              # SAFETY-FIRST (this module is distributed; a user's live VPN must
              # NEVER be killed by us). We do NOT call setAlwaysOnPackage(lockdown)
              # on a live manual VpnService: on this ROM it strips the underlying
              # routes (killing the live session) and system_server's
              # startAlwaysOnVpn then fails to bring up a manual tunnel and rolls
              # the lock back - net effect is always "tunnel dead + lock off".
              # So we only ever OBSERVE and report the tunnel's bypassable state:
              #   - non-bypassable (bypassable=false): GMS's MCS cannot unwrap it,
              #     so it is already forced through the tunnel - nothing to lock.
              #   - bypassable (bypassable=true): we CANNOT safely force it
              #     non-bypassable from the shell without killing the session, so
              #     we report it and let the user switch to global mode with a
              #     non-bypassable VPN (the only combo that both routes GMS through
              #     the tunnel AND keeps the tunnel alive). Do NOT latch (locked
              #     stays 0) so a mode/VPN change is picked up on the next poll.
              if printf '%s\n' "$ds" | grep -a 'VpnTransportInfo{' | head -n 1 | grep -aq 'bypassable=true'; then
                [ "$(cat "$VPN_STF" 2>/dev/null)" != "skip-bypassable ($pkg)" ] && \
                  { echo "skip-bypassable ($pkg)" > "$VPN_STF" 2>/dev/null;
                   log "vpn_lock: tunnel $pkg is BYPASSABLE; not applying lockdown (would kill the live session) - use global mode with a non-bypassable VPN"; }
              else
                [ "$(cat "$VPN_STF" 2>/dev/null)" != "skip ($pkg)" ] && \
                  { echo "skip ($pkg)" > "$VPN_STF" 2>/dev/null;
                   log "vpn_lock: tunnel $pkg already non-bypassable, no lock needed"; }
              fi ;;
          esac
        fi
      fi
    else
      if [ "$locked" = "1" ]; then
        # the user may have configured their own always-on while our lock was
        # up - in that case leave the state (and their settings) alone
        if vpn_user_cfg; then
          locked=2
        else
          vpn_release
          echo idle > "$VPN_STF" 2>/dev/null
          log "vpn_lock: lockdown released (tunnel down)"
        fi
      fi
      [ "$locked" = "0" ] && echo idle > "$VPN_STF" 2>/dev/null
    fi
    sleep 5
  done
}
# The GMS-push VPN monitor is an OBSERVE-ONLY indicator, gated by the user
# toggle (vpn_lock=1) since it's mainly a debugging aid and the 5s poll is not
# free. It reads the active tunnel's bypassable flag + whether GMS is routed
# through it and reports to the panel for guidance. It NEVER applies a lockdown
# (setAlwaysOnPackage would kill a live manual tunnel on this ROM). The stale-
# lock cleanup runs in BOTH branches in case an older active-lock era left a
# lock in system_server memory: release ONLY our own ephemeral lock (settings
# show no configured always-on) and only with the tunnel down.
if [ "$(settings get secure always_on_vpn_app 2>/dev/null)" = "null" ] && vpn_is_locked && \
   ! grep -q 'tun[0-9]' /proc/net/dev 2>/dev/null; then
  vpn_release
  log "vpn_monitor: released stale lockdown from previous era"
fi
if [ "$vpn_lock" = "1" ]; then
  vpn_lock_watch &
  log "vpn_monitor: observe-only watcher started"
else
  echo off > "$VPN_STF" 2>/dev/null
fi

# ---------- LSPosed system-scope fix (v1.9.5) ----------
# post-fs-data masks ro.product.locale to en-US (pre-zygote) so the lspd
# daemon's module parse skips the CN-only NPE branch that drops system-scope
# LSPosed modules from the system_server list. The parse window is over once
# system_server is up, so restore the locale shortly after boot_completed; the
# user never sees the mask. If the daemon starts after the restore is due
# (e.g. daemon killed + restarted), the locale is already back and the restore
# below is a harmless no-op.
# The resting point is the selected region identity: region_mode=overseas wrote
# en/US on purpose, so the mask is not something to undo there.
LSP_STF=$ST/lsp
loc_lang=zh
loc_reg=CN
[ "$region_mode" = "overseas" ] && { loc_lang=en; loc_reg=US; }
if [ "$lsp_fix" = "1" ]; then
  (
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
    sleep 5
    RP=/data/adb/ksu/bin/resetprop
    [ -x "$RP" ] || RP=resetprop
    "$RP" ro.product.locale.language "$loc_lang"
    "$RP" ro.product.locale.region "$loc_reg"
    echo "$(date) restored" > "$LSP_STF" 2>/dev/null
  ) &
  log "lsp_fix: locale mask restore scheduled (boot_completed+5s -> $loc_lang/$loc_reg)"
else
  echo off > "$LSP_STF" 2>/dev/null
fi

# ---------- VoLTE APN fix (v1.9.6) ----------
# Reverse-engineering trail: Settings toggle is ON (hn_volte_user_switch_N=1),
# carrier config says volte available (carrier_volte_available_bool=true) and
# the framework gate passes (com.android.ims.HwImsManagerInner#
# isVolteEnabledByPlatform -> device config && carrier config && GBA, all
# true) - yet MMTEL stays UNAVAILABLE. The actual blocker is data, not code:
# this ROM's APN DB has no type=ims row for 44054 (au), while the CN carrier
# rows carry apn=ims/type=ims (which is exactly why VoLTE "works on other
# cards"). Without it the IMS PDN is never set up; once the row exists the
# framework builds its built-in "DEFAULT IMS" profile (DNN "ims") and the
# network answers with P-CSCF + QCI5 - verified live on au. Long-term cost of
# the missing row: CS domain stuck in NOT_REG_SEARCHING, i.e. the modem keeps
# re-attempting voice registration that can never succeed on a VoLTE-only
# network (extra signaling both ways, also seen in the standby drain trace).
# Watcher: ensures one type=ims row per loaded SIM operator numeric, re-run
# only when the numeric set changes (SIM swap); idempotent, never touches
# existing rows.
VOLTE_STF=$ST/volte
volte_ensure() {  # $1 = operator numeric (e.g. 44054) -> prints ok|ins|err
  num=$1
  mcc=$(printf '%s' "$num" | cut -c 1-3)
  mnc=$(printf '%s' "$num" | cut -c 4-)
  [ -n "$mnc" ] || { echo err; return; }
  got=$(content query --uri content://telephony/carriers --projection _id \
        --where "numeric='$num' AND type='ims'" 2>/dev/null)
  case "$got" in *Row:*|*"_id="*) echo ok; return ;; esac
  if content insert --uri content://telephony/carriers \
      --bind name:s:'IMS' --bind apn:s:'ims' --bind type:s:'ims' \
      --bind numeric:s:"$num" --bind mcc:s:"$mcc" --bind mnc:s:"$mnc" \
      --bind protocol:s:'IPV4V6' --bind roaming_protocol:s:'IPV4V6' \
      --bind authtype:i:0 --bind carrier_enabled:i:1 >/dev/null 2>&1; then
    echo ins
  else
    echo err
  fi
}
volte_radio_cycle() {
  cmd connectivity airplane-mode enable  >/dev/null 2>&1
  sleep 5
  cmd connectivity airplane-mode disable >/dev/null 2>&1
}
volte_watch() {
  last=X; n=0
  while :; do
    nums=$(getprop gsm.sim.operator.numeric 2>/dev/null | tr -d ' ')
    clean=""
    OLDIFS=$IFS; IFS=,
    for p in $nums; do
      case "$p" in ""|-|*-*) ;; *)
        case ",$clean," in *",$p,"*) ;; *) clean="${clean:+$clean,}$p" ;; esac ;;
      esac
    done
    IFS=$OLDIFS
    if [ -z "$clean" ]; then
      echo wait-sim > "$VOLTE_STF" 2>/dev/null
      # fast re-poll while boot settles (3 min), then re-check every 5 min
      n=$((n+1)); [ $n -le 18 ] && sleep 10 || sleep 300
      continue
    fi
    if [ "$clean" != "$last" ]; then
      last=$clean
      ins=0; err=0
      for p in $(printf '%s' "$clean" | tr , ' '); do
        st=$(volte_ensure "$p")
        case $st in ok) : ;; ins) ins=$((ins+1)) ;; *) err=$((err+1)) ;; esac
      done
      if [ $err -gt 0 ]; then
        echo "err ($clean)" > "$VOLTE_STF" 2>/dev/null
        log "volte_fix: content provider error for $clean, retry in 2 min"
        last=X
        sleep 120
        continue
      fi
      if [ $ins -gt 0 ] && [ "$volte_radio_cycle" = "1" ]; then
        echo "radio-cycle ($clean)" > "$VOLTE_STF" 2>/dev/null
        sleep 3
        volte_radio_cycle
      fi
      echo "ok $clean inserted=$ins" > "$VOLTE_STF" 2>/dev/null
      log "volte_fix: ims APN ensured for $clean (inserted=$ins, radio_cycle=$([ $ins -gt 0 ] && echo 1 || echo 0))"
    else
      echo "ok $clean" > "$VOLTE_STF" 2>/dev/null
    fi
    sleep 300
  done
}
if [ "$volte_fix" = "1" ]; then
  volte_watch &
  log "volte_fix: ims-APN watcher started"
else
  echo off > "$VOLTE_STF" 2>/dev/null
fi

prev_charging=0
cycle=0
applied=0
voted=0
fight=0
while :; do
  if [ -f $ST/paused ]; then
    if [ "$voted" = "1" ]; then do_release; voted=0; log "votes released (paused)"; fi
    sleep 1; continue
  fi
  # refresh inputs every 10 cycles; writes run every cycle
  if [ $((cycle % 10)) -eq 0 ]; then
    ue=$(cat "$BATT_UE" 2>/dev/null)
    status=${ue#*POWER_SUPPLY_STATUS=}; status=${status%%$'\n'*}
    temp=${ue#*POWER_SUPPLY_TEMP=}; temp=${temp%%$'\n'*}
    online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
    # honor fast-charge heads keep usb/online=0 even while delivering 11V: charge
    # detection must also accept the battery status, or the unlock NEVER runs on
    # exactly the adapters it exists for (66W/80W heads)
    charging=0
    [ "$online" = "1" ] && charging=1
    case $status in Charging|Full) charging=1 ;; esac
    if [ "$protocol_poke" = "1" ] && [ "$charging" = "1" ] && [ "$prev_charging" != "1" ]; then
      poke_protocols; log "protocol poke on plug"
      { sleep 8; dump_arbitration; } &
    fi
    prev_charging=$charging
    want=0
    if [ "$charging" = "1" ]; then
      if [ "$unlock_when_screen_off" = "1" ]; then want=1
      elif [ "$screen_on_unlock" = "1" ] && screen_awake; then want=1; fi
    fi
    guarded=0
    [ "$temp_guard" != "0" ] && [ "${temp:-0}" -ge "$temp_guard" ] 2>/dev/null && guarded=1
    [ "$guarded" = "1" ] && want=0
  fi
  if [ "$want" = "1" ]; then
    [ "$voted" = "1" ] || iface_snapshot
    [ "$voted" = "1" ] || pd_snapshot
    do_unlock
    voted=1
    applied=$((applied + 1))
    [ $((applied % 600)) -eq 1 ] && \
      log "unlock applied (status=$status temp=$temp fight=$fight dcp=$(grep -m1 '^dcp ' "$IFACE/iin_limit" 2>/dev/null) rt=$(cat "$DC/charge_data/iin_rt_current" 2>/dev/null) sc=$(cat "$DC/direct_charger_sc/iin_thermal" 2>/dev/null) hsc=$(cat "$DC/direct_charger_hsc/iin_thermal" 2>/dev/null))"
  elif [ "$voted" = "1" ]; then
    # unplugged, temp_guard tripped or the screen gate closed: the vote is
    # sticky in the kernel registry, so hand the lanes back instead of leaving
    # max_iin pinned for the next (possibly vendor-throttled) session.
    do_release
    voted=0
    log "votes released (status=$status temp=$temp dcp=$(grep -m1 '^dcp ' "$IFACE/iin_limit" 2>/dev/null))"
  fi
  # re-assert preload-disable every ~60 cycles (cloud config may re-push)
  if [ "$disable_preload" = "1" ] && [ $((cycle % 60)) -eq 0 ]; then
    [ "$(getprop persist.sys.iaware.activitypreload.version)" != "0" ] && setprop persist.sys.iaware.activitypreload.version 0
    [ "$(getprop persist.sys.iaware.preloadoptenable)" != "0" ] && setprop persist.sys.iaware.preloadoptenable 0
    [ "$(getprop persist.sys.iaware.touchdownpreloadenable)" != "0" ] && setprop persist.sys.iaware.touchdownpreloadenable 0
  fi
  # FCM keep-alive: re-assert on a wall-clock schedule (default 30 min), not
  # per-cycle; piggybacks the existing loop so no extra wakeup is created.
  # date(1) runs only every 90 cycles (~27s plugged / 15min unplugged).
  # Boot boost: PowerGenie re-pushes the stock google list during its own boot,
  # after our first assert -> dense re-asserts (60s x5) close that race window.
  if [ "$fcm_unlock" = "1" ] && [ $((cycle % 90)) -eq 0 ] && [ "$fcm_avail" = "1" ]; then
    now=$(date +%s)
    fcmint=${fcm_interval:-1800}
    [ "${fcm_boot_boost:-0}" -gt 0 ] && fcmint=60
    if [ $((now - fcm_last)) -ge $fcmint ]; then
      if fcm_assert; then
        fcm_last=$now
        [ "${fcm_boot_boost:-0}" -gt 0 ] && fcm_boot_boost=$((fcm_boot_boost-1))
      else
        fcm_last=$((now - $fcmint + 120))   # retry in ~2 min
      fi
    fi
  fi
  cycle=$((cycle + 1))

  # power: fight is only meaningful while a charger is connected. Fast poll
  # (0.3s) when charging, deep 10s sleep otherwise -> ~zero idle cost.
  if [ "$charging" != "1" ]; then
    sleep 10
    continue
  fi
  sleep "$poll_interval"
done
