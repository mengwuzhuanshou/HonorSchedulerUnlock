# -*- coding: utf-8 -*-
"""eSIM 电子围栏 hook 构建配置（HonorSchedulerUnlock 内置，随 esim_fix 开关交付）。"""
MODULE = {
    "package": "com.tamer.esimfix",
    "version_name": "1.0.0",
    "version_code": 1,
    "app_label": u"eSIM 围栏去除 (HonorSchedulerUnlock)",
    "xposed_description": u"去除荣耀 eSIM 下载/激活的电子围栏（com.hihonor.esimservice 的 checkLocationAndOperator 恒放行），装/激活外置 eSIM 不再需要模拟位置。由 HonorSchedulerUnlock 的 esim_fix 开关安装。",
    "xposed_scope": "com.hihonor.esimservice",
    "dist_name": "esimfix-v%s.apk",
    "libxposed": True,
    "xposed_entry": "com.tamer.esimfix.MainHook",
}