package com.tamer.esimfix;

import android.util.Log;

import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicBoolean;

import io.github.libxposed.api.XposedInterface;
import io.github.libxposed.api.XposedModule;
import io.github.libxposed.api.XposedModuleInterface;

/**
 * eSIM 电子围栏去除（HonorSchedulerUnlock 内置 hook，随 esim_fix 开关交付）。
 *
 * 落点（静态反编译坐实，HnESIMService.apk / com.hihonor.esimservice）：
 *   defpackage.e#checkLocationAndOperator(String) 是整条 eSIM 栈里唯一的位置门。
 *   它只被两处消费：
 *     - HnEuiccServiceImpl#onDownloadSubscription:863（下载/激活流，checkResult!=0 即 290 拦截）
 *     - EsimServiceProvider#is_allowd_to_download:42（Manager DownloadSwitchFragment 查询）
 *   内部 getCurrentArea() 经 HiGeo binder(com.hihonor.lbs tx85) 拿 GPS 落 china.geojson
 *   多边形的 CN/非CN 判定：外置外国 profile（profileMcc!=460、非中国运营商）必须 area==1
 *   （海外）才返回 0 放行；area==0(CN) 返回 1 拦截。这就是「装/激活外置 eSIM 要模拟位置」
 *   的根源——模拟位置让 HiGeo 返回非 CN。
 *
 * 本 hook 把 checkLocationAndOperator 短路成恒 0（放行），等价于永久「海外」判定，
 * 于是下载/激活不再读位置、不再需要模拟位置。纯切换（Enable 开关）链路五层反编译均无
 * 位置门，不在本 hook 范围（其「System busy」是通用错误罩，真实码需 logcat 另查）。
 *
 * 类名 "e" 是此固件构建的混淆名（与 eid_guard 的 sha pin 同口径，按构建钉死）；
 * 方法名 checkLocationAndOperator 未混淆。若该固件类名漂移，hook 会打 ERROR 日志暴露，
 * 不会静默失效。
 */
public class MainHook extends XposedModule {
    private static final String TAG = "EsimFix";
    private static final String TARGET_PKG = "com.hihonor.esimservice";
    private static final String TARGET_CLS = "e";
    private static final String TARGET_METHOD = "checkLocationAndOperator";

    private final AtomicBoolean installed = new AtomicBoolean(false);
    private final AtomicBoolean firedProbe = new AtomicBoolean(false);
    private volatile String processName = "unknown";

    public MainHook() {
    }

    @Override
    public void onModuleLoaded(XposedModuleInterface.ModuleLoadedParam param) {
        this.processName = param.getProcessName();
        log(Log.INFO, TAG, "module loaded: process=" + processName
                + " framework=" + getFrameworkName() + " api=" + getApiVersion());
    }

    @Override
    public void onPackageReady(XposedModuleInterface.PackageReadyParam param) {
        try {
            if (!TARGET_PKG.equals(param.getPackageName())) {
                return;
            }
            if (!installed.compareAndSet(false, true)) {
                return;
            }
            ClassLoader cl = param.getClassLoader();
            Class<?> cls;
            try {
                cls = cl.loadClass(TARGET_CLS);
            } catch (Throwable t) {
                log(Log.ERROR, TAG, "target class '" + TARGET_CLS
                        + "' not found in " + TARGET_PKG + " (obfuscation drift?) - geofence NOT bypassed", t);
                return;
            }
            Method m;
            try {
                m = cls.getDeclaredMethod(TARGET_METHOD, String.class);
            } catch (Throwable t) {
                log(Log.ERROR, TAG, "method " + TARGET_METHOD + "(String) not found on "
                        + TARGET_CLS + " - geofence NOT bypassed", t);
                return;
            }
            hook(m).setPriority(Integer.MAX_VALUE)
                    .setExceptionMode(XposedInterface.ExceptionMode.PROTECTIVE)
                    .intercept(new XposedInterface.Hooker() {
                        @Override
                        public Object intercept(XposedInterface.Chain chain) throws Throwable {
                            if (firedProbe.compareAndSet(false, true)) {
                                Object name = null;
                                try {
                                    name = chain.getArg(0);
                                } catch (Throwable ignored) {
                                }
                                log(Log.INFO, TAG, "geofence bypass fired: "
                                        + TARGET_CLS + "." + TARGET_METHOD + "(" + name + ") -> 0");
                            }
                            // 恒 0 = 放行下载/激活，不读位置。不调用 chain.proceed()。
                            return Integer.valueOf(0);
                        }
                    });
            log(Log.INFO, TAG, "hook installed: " + TARGET_PKG + "/" + TARGET_CLS
                    + "." + TARGET_METHOD + " -> 0 (process=" + processName + ")");
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "onPackageReady crashed", t);
        }
    }
}