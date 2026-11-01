// 键盘皮肤（KeyboardSkin）1.1
// 1.0 的教训：插入自己的 view + 把"类名含 Background"的层透明掉 → 用户反馈完全没效果。
// 说明键盘背景实例的类名不含 Background，或它不在我们遍历的子树里。
//
// 1.1 改为【尺寸判据 + 直接赋值】双保险：
//   A) 递归遍历键盘视图树，找所有 Spl/itImageView 类，用 frame 尺寸判断谁是"背景"
//      （背景 = 接近键盘整宽；键帽 = 小方块）
//   B) 直接给该视图的所有 UIImageView 子视图赋 image（0.6 已证明这条路有效）
//   C) 同时把系统模糊/材质层 alpha 置 0，避免盖住
//   D) 我们自己的背景 view 仍插在 index 0 兜底
// 全程 @try 包裹 + 完整层级日志，失败也能定位。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <CydiaSubstrate/CydiaSubstrate.h>
#include <dlfcn.h>

#define KS_DOMAIN  "com.ning.keyboardskin"
#define KS_CHANGED "com.ning.keyboardskin.changed"
#define KS_LOG     "/var/mobile/Library/KeyboardSkin.log"
#define KS_DIR     "/var/mobile/Library/KeyboardSkin"
#define KS_THEMES  "/var/mobile/Library/KeyboardSkin/Themes"
#define KS_SINGLE  "/var/mobile/Library/KeyboardSkin/background.png"

#pragma mark - 日志

static void KSLog(NSString *format, ...) {
    // 不断清空日志：每个进程都会写同一文件，最早的进程会被后来的覆盖。
    // 改为：始终追加，并带进程名+PID，方便区分哪个进程在写。
    // 不删除旧日志；键盘服务、宿主 App、设置进程会同时写入同一文件。
    // 只追加并带 PID，避免后启动进程清空前一个进程的证据。
    static NSInteger lines = 0;
    if (lines > 8000) return;
    va_list args; va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *proc = NSProcessInfo.processInfo.processName;
    NSString *out = [NSString stringWithFormat:@"[ks %@ pid=%d proc=%@] %@\n",
        [NSDate.date descriptionWithLocale:@"HH:mm:ss"], getpid(), proc, s];
    lines++;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@KS_LOG];
    if (!fh) {
        [@"" writeToFile:@KS_LOG atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        fh = [NSFileHandle fileHandleForWritingAtPath:@KS_LOG];
    }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}


#pragma mark - 偏好

static BOOL ksEnabled = YES;
static BOOL ksHideStock = YES;
static BOOL ksEnableImageReplace = NO;
static BOOL ksColorEngine = YES;     // 颜色引擎（Laetus 式着色）独立开关
static NSString *ksThemeName = nil;
static NSString *ksThemePath = nil;
static NSInteger ksGen = 0;
static CGFloat ksCornerRadius = 0;
static BOOL ksHideKeyCaps = NO;      // 隐藏键帽（保留字母）
static NSInteger ksFillMode = 0;     // 0填充 1适应 2拉伸 3居中
static CGFloat ksScale = 1.0;        // 背景缩放
static CGFloat ksOffsetY = 0;        // 背景垂直偏移(点)

static BOOL KSBool(NSString *key, BOOL dflt) {
    CFPreferencesAppSynchronize(CFSTR(KS_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KS_DOMAIN));
    BOOL out = dflt;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) out = [(id)CFBridgingRelease(v) boolValue];
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue(v, kCFNumberIntType, &n); out = n != 0; }
        else CFRelease(v);
    }
    return out;
}

static NSInteger KSInt(NSString *key, NSInteger dflt) {
    CFPreferencesAppSynchronize(CFSTR(KS_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KS_DOMAIN));
    NSInteger out = dflt;
    if (v) {
        CFTypeID t = CFGetTypeID(v);
        if (t == CFNumberGetTypeID()) {
            long long n = dflt; CFNumberGetValue(v, kCFNumberLongLongType, &n); out = n;
        } else if (t == CFStringGetTypeID()) {
            out = [(__bridge NSString *)v integerValue];   // PSEditTextCell 存的是字符串
        }
        CFRelease(v);
    }
    if (out != dflt) {
        static int logged = 0;
        if (logged++ < 8) KSLog(@"pref %@ = %ld (string-friendly)", key, (long)out);
    }
    return out;
}

static NSString *KSStr(NSString *key) {
    CFPreferencesAppSynchronize(CFSTR(KS_DOMAIN));
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(KS_DOMAIN));
    return v ? [(id)CFBridgingRelease(v) copy] : nil;
}

#pragma mark - 主题

static NSArray *KSThemeDirs(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *item in [fm contentsOfDirectoryAtPath:@KS_THEMES error:NULL]) {
        if ([item hasPrefix:@"."]) continue;
        NSString *full = [@KS_THEMES stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) [out addObject:full];
    }
    return out;
}

static void KSResolveTheme(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:@KS_THEMES withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *resolved = nil;
    if (ksThemeName.length) {
        NSString *p = [@KS_THEMES stringByAppendingPathComponent:ksThemeName];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) resolved = p;
    }
    if (!resolved) {
        NSArray *dirs = KSThemeDirs();
        // 优先名字含 Light 的主题，其次第一个
        for (NSString *d in dirs) {
            if ([d.lastPathComponent containsString:@"Light"]) { resolved = d; break; }
        }
        if (!resolved && dirs.count) resolved = dirs.firstObject;
    }
    if (!resolved && [fm fileExistsAtPath:@KS_SINGLE]) resolved = @KS_DIR;
    if (resolved && ![resolved isEqualToString:ksThemePath]) {
        ksThemePath = resolved; ksGen++;
        KSLog(@"theme -> %@ (gen %ld)", ksThemePath, (long)ksGen);
    } else if (!resolved && ksThemePath) {
        ksThemePath = nil; ksGen++;
        KSLog(@"theme cleared");
    }
}

static void KSReloadPrefs(void) {
    ksEnabled = KSBool(@"Enabled", YES);
    ksHideStock = KSBool(@"HideStock", YES);
    ksEnableImageReplace = KSBool(@"EnableImageReplace", NO);
    ksColorEngine = KSBool(@"ColorEngineEnabled", YES);
    ksCornerRadius = (CGFloat)KSInt(@"CornerRadius", 0);
    ksHideKeyCaps = KSBool(@"HideKeyCaps", NO);
    ksFillMode = KSInt(@"FillMode", 0);
    ksScale = (CGFloat)KSInt(@"BgScale", 100) / 100.0;
    if (ksScale < 0.5) ksScale = 0.5;
    if (ksScale > 2.0) ksScale = 2.0;
    ksOffsetY = (CGFloat)KSInt(@"BgOffsetY", 0);
    if (ksOffsetY < -100) ksOffsetY = -100;
    if (ksOffsetY > 100) ksOffsetY = 100;
    NSString *t = KSStr(@"ActiveTheme");
    if (![ksThemeName isEqualToString:t]) { ksThemeName = t; KSLog(@"prefs theme='%@'", t); }
    KSResolveTheme();
}

#pragma mark - 颜色引擎（UIKBGetNamedColor）

static uint32_t KSHexVal(unichar c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}
static UIColor *KSColorFromHex(NSString *hex) {
    if (!hex || hex.length < 6) return nil;
    NSString *h = hex;
    if ([h hasPrefix:@"#"]) h = [h substringFromIndex:1];
    if (h.length < 6) return nil;
    uint32_t r = (KSHexVal([h characterAtIndex:0]) << 4) | KSHexVal([h characterAtIndex:1]);
    uint32_t g = (KSHexVal([h characterAtIndex:2]) << 4) | KSHexVal([h characterAtIndex:3]);
    uint32_t b = (KSHexVal([h characterAtIndex:4]) << 4) | KSHexVal([h characterAtIndex:5]);
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}
static UIColor *KSColorRGB(int rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSString *KSPrefString(NSString *key) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                     (__bridge CFStringRef)@"com.ning.keyboardskin"));
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static UIColor *KSColorForFactoryKey(NSString *key) {
    BOOL dark = [ksThemeName localizedCaseInsensitiveContainsString:@"dark"];
    NSString *prefKey = nil;
    NSString *fallback = nil;
    if ([key isEqualToString:@"keycap"]) { prefKey = @"ColorKeycap"; fallback = dark ? @"#3a3a42" : @"#ffffff"; }
    else if ([key isEqualToString:@"ctrlbg"]) { prefKey = @"ColorCtrlBG"; fallback = dark ? @"#47474f" : @"#efeff4"; }
    else if ([key isEqualToString:@"ctrlfg"]) { prefKey = @"ColorCtrlFG"; fallback = dark ? @"#ffffff" : @"#1a1a1a"; }
    else if ([key isEqualToString:@"shadow"]) { prefKey = @"ColorShadow"; fallback = @"#000000"; }
    else if ([key isEqualToString:@"lowbg"]) { prefKey = @"ColorLowBG"; fallback = dark ? @"#26262a" : @"#e8e8ec"; }
    else return nil;
    UIColor *c = KSColorFromHex(KSPrefString(prefKey));
    return c ?: KSColorFromHex(fallback);
}

static UIColor *ksColourForName(NSString *n) {
    BOOL dark = [ksThemeName localizedCaseInsensitiveContainsString:@"dark"];
    if ([n isEqualToString:@"keyboardBackgroundLightColor"] || [n isEqualToString:@"keyboardBackgroundDarkColor"]) {
        return dark ? KSColorRGB(0x26262a) : KSColorRGB(0xe8e8ec);
    }
    if ([n isEqualToString:@"keyboardKeyColor"] || [n isEqualToString:@"keyboardCapColor"]) {
        return dark ? KSColorRGB(0x37373d) : KSColorRGB(0xffffff);
    }
    if ([n isEqualToString:@"keyboardTextColor"]) {
        return dark ? KSColorRGB(0xffffff) : KSColorRGB(0x1a1a1a);
    }
    if ([n isEqualToString:@"popupBackgroundColor"]) {
        return dark ? KSColorRGB(0x3a3a42) : KSColorRGB(0xffffff);
    }
    if ([n isEqualToString:@"popupTextColor"]) {
        return dark ? KSColorRGB(0xffffff) : KSColorRGB(0x1a1a1a);
    }
    if ([n isEqualToString:@"predictionBarBackgroundColor"]) {
        return dark ? KSColorRGB(0x26262a) : KSColorRGB(0xf0f0f4);
    }
    if ([n isEqualToString:@"predictionTextColor"]) {
        return dark ? KSColorRGB(0xdddddd) : KSColorRGB(0x222222);
    }
    if ([n isEqualToString:@"emojiSearchBackgroundColor"]) {
        return dark ? KSColorRGB(0x37373d) : KSColorRGB(0xffffff);
    }
    return nil;
}

static UIColor *(*orig_getNamedColor)(CFStringRef) = NULL;
static UIColor *ksGetNamedColor(CFStringRef name) {
    if (name && ksEnabled && ksColorEngine) {
        NSString *n = (__bridge NSString *)name;
        if ([n hasPrefix:@"ks_"]) {
            NSString *key = [n substringFromIndex:3];
            KSLog(@"colour hit ks_%@ -> %@", key, [key uppercaseString]);
            return KSColorForFactoryKey(key);
        }
        UIColor *c = ksColourForName(n);
        if (c) return c;
        static NSMutableSet *seen;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
        if (![seen containsObject:n]) {
            [seen addObject:n];
            KSLog(@"colour req: %@", n);
        }
    }
    return ((UIColor *(*)(CFStringRef))orig_getNamedColor)(name);
}

// ---- UIKBRenderFactory 返回“颜色名”，系统再经 UIKBGetNamedColor 取色。
// 我们 hook 颜色名方法，改成自家前缀色名，再在 UIKBGetNamedColor 里拦住返回主题色。
static NSString *KSFactoryColorName(NSString *key) {
    return [@"ks_" stringByAppendingString:key];
}
typedef id (*RenderFactoryFn)(id, SEL);
static RenderFactoryFn orig_factoryDefaultKeyBG;
static id ks_factoryDefaultKeyBG(id self, SEL _cmd) {
    if (!ksEnabled || !ksColorEngine) return orig_factoryDefaultKeyBG(self, _cmd);
    id orig = orig_factoryDefaultKeyBG(self, _cmd);
    KSLog(@"factory defaultKeyBG: %@", orig);
    return KSFactoryColorName(@"keycap");
}
static RenderFactoryFn orig_factoryCtrlBG;
static id ks_factoryCtrlBG(id self, SEL _cmd) {
    if (!ksEnabled || !ksColorEngine) return orig_factoryCtrlBG(self, _cmd);
    id orig = orig_factoryCtrlBG(self, _cmd);
    KSLog(@"factory ctrlBG: %@", orig);
    return KSFactoryColorName(@"ctrlbg");
}
static RenderFactoryFn orig_factoryCtrlFG;
static id ks_factoryCtrlFG(id self, SEL _cmd) {
    if (!ksEnabled || !ksColorEngine) return orig_factoryCtrlFG(self, _cmd);
    id orig = orig_factoryCtrlFG(self, _cmd);
    KSLog(@"factory ctrlFG: %@", orig);
    return KSFactoryColorName(@"ctrlfg");
}
static RenderFactoryFn orig_factoryShadow;
static id ks_factoryShadow(id self, SEL _cmd) {
    if (!ksEnabled || !ksColorEngine) return orig_factoryShadow(self, _cmd);
    id orig = orig_factoryShadow(self, _cmd);
    KSLog(@"factory shadow: %@", orig);
    return KSFactoryColorName(@"shadow");
}
static RenderFactoryFn orig_factoryLowBG;
static id ks_factoryLowBG(id self, SEL _cmd) {
    if (!ksEnabled || !ksColorEngine) return orig_factoryLowBG(self, _cmd);
    id orig = orig_factoryLowBG(self, _cmd);
    KSLog(@"factory lowBG: %@", orig);
    return KSFactoryColorName(@"lowbg");
}

static void KSHookFactoryColorNames(void) {
    Class cls = NSClassFromString(@"UIKBRenderFactory");
    if (!cls) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL s;
        s = NSSelectorFromString(@"defaultKeyBackgroundColorName");
        if (s && [cls instancesRespondToSelector:s] && !orig_factoryDefaultKeyBG)
            MSHookMessageEx(cls, s, (IMP)ks_factoryDefaultKeyBG, (IMP *)&orig_factoryDefaultKeyBG);
        s = NSSelectorFromString(@"controlKeyBackgroundColorName");
        if (s && [cls instancesRespondToSelector:s] && !orig_factoryCtrlBG)
            MSHookMessageEx(cls, s, (IMP)ks_factoryCtrlBG, (IMP *)&orig_factoryCtrlBG);
        s = NSSelectorFromString(@"controlKeyForegroundColorName");
        if (s && [cls instancesRespondToSelector:s] && !orig_factoryCtrlFG)
            MSHookMessageEx(cls, s, (IMP)ks_factoryCtrlFG, (IMP *)&orig_factoryCtrlFG);
        s = NSSelectorFromString(@"defaultKeyShadowColorName");
        if (s && [cls instancesRespondToSelector:s] && !orig_factoryShadow)
            MSHookMessageEx(cls, s, (IMP)ks_factoryShadow, (IMP *)&orig_factoryShadow);
        s = NSSelectorFromString(@"lowQualityLayeredBackgroundColorName");
        if (s && [cls instancesRespondToSelector:s] && !orig_factoryLowBG)
            MSHookMessageEx(cls, s, (IMP)ks_factoryLowBG, (IMP *)&orig_factoryLowBG);
        KSLog(@"hook: UIKBRenderFactory color name methods");
    });
}


#pragma mark - 图层处理


static NSString *KSClassOf(UIView *v) { return NSStringFromClass([v class]); }





// 亮度方差（12x12 采样）：背景层低方差，键帽/文字层高方差

static double KSImageVariance(UIImage *img) {
    if (!img) return -1;
    CGImageRef cg = img.CGImage;
    if (!cg) return -1;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return -1;
    const int N = 12;
    unsigned char buf[N * N * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs,
        kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault);
    CGColorSpaceRelease(cs);
    if (!ctx) return -1;
    CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(ctx);
    double sum = 0, sum2 = 0;
    for (int i = 0; i < N * N; i++) {
        double y = 0.299*buf[i*4] + 0.587*buf[i*4+1] + 0.114*buf[i*4+2];
        sum += y; sum2 += y*y;
    }
    double n = (double)(N * N);
    double mean = sum / n;
    return sum2 / n - mean * mean;
}



#pragma mark - Hooks

// setImage:cachedWidth:keyplane: —— 纯观测（不替换）。
// Laetus 的双图族替换在 iOS 17 上该入口从未被调用，且事后改写 contents
// 会被系统重绘覆盖并可能误伤键帽/文字，故仅在 keyplane 切换/图像更新时
// 记录 filterType/plane/var，用于诊断真实图层语义。
static IMP orig_setImage = NULL;
static void ks_setImage(UIView *self, SEL _cmd, UIImage *image, double width, id keyplane) {
    @try {
        if (ksEnabled && ksThemePath.length && image) {
            NSString *plane = nil;
            @try { plane = [keyplane valueForKey:@"name"]; } @catch (__unused NSException *e) {}
            static int logs = 0;
            if (logs++ < 30) {
                double var = KSImageVariance(image);
                KSLog(@"setImage(obs) class=%@ w=%.0f plane=%@ var=%.0f",
                      KSClassOf(self), self.bounds.size.width, plane ?: @"-", var);
            }
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - 安装

static void KSConfigChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *p, CFDictionaryRef d) {
    KSReloadPrefs();
    KSLog(@"config changed");
}

static void KSInstall(void) {
    // 只保留两个不动渲染的安全入口：
    //  1) UIKBSplitImageView -setImage:cachedWidth:keyplane:  (纯观测，诊断用)
    //  2) UIKBGetNamedColor                             (颜色引擎，Laetus 正统)
    Class split = NSClassFromString(@"UIKBSplitImageView");
    if (split && !orig_setImage) {
        SEL ss = NSSelectorFromString(@"setImage:cachedWidth:keyplane:");
        if ([split instancesRespondToSelector:ss]) {
            MSHookMessageEx(split, ss, (IMP)ks_setImage, (IMP *)&orig_setImage);
            KSLog(@"hook: UIKBSplitImageView setImage:cachedWidth:keyplane: (obs)");
        }
    }
    KSHookFactoryColorNames();
    void *namedSym = dlsym(RTLD_DEFAULT, "UIKBGetNamedColor");
    if (namedSym && !orig_getNamedColor) {
        MSHookFunction(namedSym, (void *)ksGetNamedColor, (void **)&orig_getNamedColor);
        KSLog(@"hook: UIKBGetNamedColor");
    }
}


__attribute__((constructor))
static void KSInit(void) {
    @autoreleasepool {
        KSReloadPrefs();
        KSLog(@"KeyboardSkin 1.9.4 init [%@] — enabled=%d hideStock=%d theme='%@' path=%@",
              NSProcessInfo.processInfo.processName, ksEnabled, ksHideStock, ksThemeName, ksThemePath);
        KSInstall();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSInstall(); });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &KSConfigChanged, CFSTR(KS_CHANGED), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
