package com.twinby.adblock;

import android.view.View;
import android.view.ViewGroup;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;
import de.robv.android.xposed.IXposedHookLoadPackage;

/**
 * Xposed/LSPosed/Vector-модуль: убирает рекламу Yandex Mobile Ads в приложении Twinby.
 *
 * Работает только внутри процесса com.twinby. Не трогает анкеты, чат и сеть приложения —
 * только рекламные классы Yandex SDK. Любой несработавший хук логируется и не ломает остальные.
 *
 * Twinby на Flutter, но рекламу (и всплывающие вставки, и баннер в ленте) рисует нативный
 * Yandex SDK через плагин flutter_yandex_ad, поэтому классы ниже — обычные Android-классы,
 * доступные для хука.
 *
 * Имена классов Yandex SDK публичны и обычно не обфусцируются. Если в конкретной сборке
 * что-то называется иначе, в logcat (тег TwinbyAdBlock) будет видно, какие классы найдены,
 * а какие нет — по этому логу хук дорабатывается точечно.
 */
public class TwinbyAdHook implements IXposedHookLoadPackage {

    private static final String TAG = "TwinbyAdBlock";
    private static final String TARGET = "com.twinby";

    // Интерстишелы / rewarded: гасим показ.
    private static final String[] INTERSTITIAL_CLASSES = {
            "com.yandex.mobile.ads.interstitial.InterstitialAd",
            "com.yandex.mobile.ads.rewarded.RewardedAd",
    };

    // Баннерные / нативные View: не грузим креатив и схлопываем вью.
    private static final String[] BANNER_VIEW_CLASSES = {
            "com.yandex.mobile.ads.banner.BannerAdView",
            "com.yandex.mobile.ads.nativeads.NativeBannerView",
            "com.yandex.mobile.ads.nativeads.NativeAdView",
            "com.yandex.mobile.ads.nativeads.template.appearance.NativeBannerView",
    };

    // Загрузчики нативной рекламы: гасим запрос, чтобы в ленту не прилетал ad.
    private static final String[] AD_LOADER_CLASSES = {
            "com.yandex.mobile.ads.nativeads.NativeAdLoader",
            "com.yandex.mobile.ads.nativeads.NativeBulkAdLoader",
            "com.yandex.mobile.ads.interstitial.InterstitialAdLoader",
            "com.yandex.mobile.ads.rewarded.RewardedAdLoader",
    };

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (!TARGET.equals(lpparam.packageName)) {
            return;
        }
        log("загружен процесс Twinby, ставлю хуки рекламы");

        ClassLoader cl = lpparam.classLoader;

        for (String cls : INTERSTITIAL_CLASSES) {
            hookMethodsByName(cl, cls, "show", BLOCK_WITH_LOG(cls + ".show"));
            hookMethodsByName(cl, cls, "loadAd", BLOCK_WITH_LOG(cls + ".loadAd"));
        }

        for (String cls : AD_LOADER_CLASSES) {
            hookMethodsByName(cl, cls, "loadAd", BLOCK_WITH_LOG(cls + ".loadAd"));
            hookMethodsByName(cl, cls, "loadAds", BLOCK_WITH_LOG(cls + ".loadAds"));
            hookMethodsByName(cl, cls, "loadBulkAds", BLOCK_WITH_LOG(cls + ".loadBulkAds"));
        }

        for (String cls : BANNER_VIEW_CLASSES) {
            // 1) не грузим рекламу в баннерные вью
            hookMethodsByName(cl, cls, "loadAd", BLOCK_WITH_LOG(cls + ".loadAd"));
            hookMethodsByName(cl, cls, "setAd", BLOCK_WITH_LOG(cls + ".setAd"));
            hookMethodsByName(cl, cls, "setNativeAd", BLOCK_WITH_LOG(cls + ".setNativeAd"));
            // 2) схлопываем вью, как только она появилась
            collapseView(cl, cls);
        }
    }

    /** Блокирует метод: ничего не делает и возвращает void/null, с записью в лог. */
    private static XC_MethodHook BLOCK_WITH_LOG(final String what) {
        return new XC_MethodReplacement() {
            @Override
            protected Object replaceHookedMethod(MethodHookParam param) {
                log("заблокирован вызов " + what);
                return null;
            }
        };
    }

    /** Хукает все перегрузки метода с данным именем, если класс и метод существуют. */
    private void hookMethodsByName(ClassLoader cl, String className, String methodName,
                                   XC_MethodHook hook) {
        try {
            Class<?> clazz = XposedHelpers.findClassIfExists(className, cl);
            if (clazz == null) {
                return; // класса нет в этой сборке — молча пропускаем
            }
            int count = 0;
            for (java.lang.reflect.Method m : clazz.getDeclaredMethods()) {
                if (m.getName().equals(methodName)) {
                    try {
                        XposedBridge.hookMethod(m, hook);
                        count++;
                    } catch (Throwable t) {
                        log("не удалось хукнуть " + className + "." + methodName + ": " + t);
                    }
                }
            }
            if (count > 0) {
                log("хук поставлен: " + className + "." + methodName + " (" + count + ")");
            }
        } catch (Throwable t) {
            log("ошибка при хуке " + className + "." + methodName + ": " + t);
        }
    }

    /** После создания рекламной View делает её невидимой и нулевой высоты. */
    private void collapseView(ClassLoader cl, String className) {
        try {
            Class<?> clazz = XposedHelpers.findClassIfExists(className, cl);
            if (clazz == null || !View.class.isAssignableFrom(clazz)) {
                return;
            }
            XposedBridge.hookAllConstructors(clazz, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    final View v = (View) param.thisObject;
                    v.post(new Runnable() {
                        @Override
                        public void run() {
                            try {
                                v.setVisibility(View.GONE);
                                ViewGroup.LayoutParams lp = v.getLayoutParams();
                                if (lp != null) {
                                    lp.height = 0;
                                    v.setLayoutParams(lp);
                                }
                            } catch (Throwable t) {
                                log("не удалось схлопнуть вью " + className + ": " + t);
                            }
                        }
                    });
                }
            });
            log("схлопывание вью включено: " + className);
        } catch (Throwable t) {
            log("ошибка collapseView " + className + ": " + t);
        }
    }

    private static void log(String msg) {
        XposedBridge.log(TAG + ": " + msg);
    }
}
