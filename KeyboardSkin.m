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
static NSString *ksThemeName = nil;
static NSString *ksThemePath = nil;
static NSInteger ksGen = 0;
static NSString *ksLastPlane = nil;
static NSString *KSLastPlaneName(void) { return ksLastPlane; }
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

static UIColor *KSColorRGB(int rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
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
    if (name && ksEnabled) {
        NSString *n = (__bridge NSString *)name;
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

#pragma mark - keyplane → 键名

static NSString *KSKeyForPlane(NSString *name) {
    if (!name.length) return @"KeyboardMainBG";
    NSString *p = name.lowercaseString;
    if ([p containsString:@"number"] || [p containsString:@"pad"]) return @"KeyboardNumbersBG";
    if ([p containsString:@"emoji"]) return @"KeyboardEmojiBG";
    if ([p containsString:@"dictation"]) return @"KeyboardDictationBG";
    if ([p containsString:@"autofill"]) return @"KeyboardAutoFillBG";
    if ([p containsString:@"picker"]) return @"KeyboardPickerBG";
    return @"KeyboardMainBG";
}



#pragma mark - 图片

static NSString *KSHeightSuffix(void) {
    static NSString *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat pt = UIScreen.mainScreen.bounds.size.height;
        if      (pt >= 930) s = @"932h";
        else if (pt >= 890) s = @"896h";
        else if (pt >= 850) s = @"852h";
        else if (pt >= 840) s = @"844h";
        else if (pt >= 810) s = @"812h";
        else if (pt >= 730) s = @"736h";
        else if (pt >= 660) s = @"667h";
        else s = nil;
    });
    return s;
}

static UIImage *KSLoad(NSString *path) {
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    return [UIImage imageWithCGImage:raw.CGImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
}

static NSMutableDictionary *ksCache;

static NSArray *KSAlternateThemePaths(void) {
    // 内置主题在 jbroot 内时的备用路径
    NSMutableArray *out = [NSMutableArray array];
    if (!ksThemeName.length) return out;
    for (NSString *root in @[@"/var/jb/Library/KeyboardSkin/Themes", @"/Library/KeyboardSkin/Themes"]) {
        NSString *p = [root stringByAppendingPathComponent:ksThemeName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) [out addObject:p];
    }
    return out;
}

static UIImage *KSImageForKey(NSString *key, BOOL landscape) {
    if (!key.length) return nil;
    if (!ksThemePath) {
        NSArray *alts = KSAlternateThemePaths();
        if (alts.count) ksThemePath = alts.firstObject;
    }
    if (!ksThemePath) return nil;
    NSString *orient = landscape ? @"Landscape" : @"Portrait";
    NSString *ck = [NSString stringWithFormat:@"%@|%@|gen%ld", key, orient, (long)ksGen];
    if (!ksCache) ksCache = [NSMutableDictionary new];
    UIImage *hit = ksCache[ck];
    if (hit) return hit;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *h = KSHeightSuffix();
    NSArray *scales = @[@"@3x", @"@2x", @""];
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:ksThemePath];
    if (![ksThemePath isEqualToString:@KS_DIR]) {
        for (NSString *sub in @[@"Images", @"images", @"Image"]) {
            NSString *p = [ksThemePath stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) [dirs addObject:p];
        }
    }
    NSMutableArray *names = [NSMutableArray array];
    // Laetus 官方命名：<key><Orientation>-<height>@3x.png（key 与方向之间没有连字符）
    for (NSString *sc in scales) if (h) [names addObject:[NSString stringWithFormat:@"%@%@-%@%@.png", key, orient, h, sc]];
    for (NSString *sc in scales) [names addObject:[NSString stringWithFormat:@"%@%@%@.png", key, orient, sc]];
    // 兼容写法：带连字符
    for (NSString *sc in scales) if (h) [names addObject:[NSString stringWithFormat:@"%@-%@-%@%@.png", key, orient, h, sc]];
    for (NSString *sc in scales) [names addObject:[NSString stringWithFormat:@"%@-%@%@.png", key, orient, sc]];
    for (NSString *sc in scales) if (h) [names addObject:[NSString stringWithFormat:@"%@-%@%@.png", key, h, sc]];
    for (NSString *sc in scales) [names addObject:[NSString stringWithFormat:@"%@%@.png", key, sc]];
    if ([h isEqualToString:@"932h"] || [h isEqualToString:@"926h"]) {
        for (NSString *sc in scales) {
            [names addObject:[NSString stringWithFormat:@"%@%@-896h%@.png", key, orient, sc]];
            [names addObject:[NSString stringWithFormat:@"%@-%@-896h%@.png", key, orient, sc]];
        }
    }
    if ([h isEqualToString:@"844h"]) {
        for (NSString *sc in scales) {
            [names addObject:[NSString stringWithFormat:@"%@%@-812h%@.png", key, orient, sc]];
            [names addObject:[NSString stringWithFormat:@"%@-%@-812h%@.png", key, orient, sc]];
        }
    }

    for (NSString *dir in dirs) {
        for (NSString *n in names) {
            NSString *p = [dir stringByAppendingPathComponent:n];
            if ([fm fileExistsAtPath:p]) {
                UIImage *img = KSLoad(p);
                if (img) { ksCache[ck] = img; KSLog(@"img: %@/%@", dir.lastPathComponent, n); return img; }
            }
        }
        NSString *best = nil;
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
            if (![f hasPrefix:key]) continue;
            if (orient.length && ![f containsString:orient]) continue;
            if (!best || f.length > best.length) best = f;
        }
        if (best) {
            UIImage *img = KSLoad([dir stringByAppendingPathComponent:best]);
            if (img) { ksCache[ck] = img; KSLog(@"img(prefix): %@/%@", dir.lastPathComponent, best); return img; }
        }
    }
    // 主题内背景兜底：MainBG -> NumbersBG -> EmojiBG
    if ([key isEqualToString:@"KeyboardMainBG"]) {
        for (NSString *fb in @[@"KeyboardNumbersBG", @"KeyboardEmojiBG"]) {
            UIImage *img = KSImageForKey(fb, landscape);
            if (img) { ksCache[ck] = img; KSLog(@"img(theme-fallback): %@", fb); return img; }
        }
    }
    // 单图兜底
    if ([fm fileExistsAtPath:@KS_SINGLE]) {
        UIImage *img = KSLoad(@KS_SINGLE);
        if (img) { ksCache[ck] = img; KSLog(@"img: background.png (single)"); return img; }
    }
    return nil;
}

#pragma mark - 图层处理

static const char kKSAssocBackground = '\0';
static const char kKSAssocColor = '\1';

static NSString *KSClassOf(UIView *v) { return NSStringFromClass([v class]); }





// 亮度方差（12x12 采样）：背景层低方差，键帽/文字层高方差

// 从视图的 CALayer.contents 取 CGImage（iOS17 键面贴图存在这里，不是 UIImageView.image）
static CGImageRef KSContentCGImage(UIView *v) {
    id c = v.layer.contents;
    if (c) {
        CFTypeRef obj = (__bridge CFTypeRef)c;
        if (CFGetTypeID(obj) == CGImageGetTypeID()) return (__bridge CGImageRef)c;
        if ([c isKindOfClass:UIImage.class]) {
            UIImage *u = (UIImage *)c;
            return u.CGImage ?: NULL;
        }
    }
    for (UIView *s2 in v.subviews) {
        CGImageRef g = KSContentCGImage(s2);
        if (g) return g;
    }
    return NULL;
}

static double KSVarianceOfCGImage(CGImageRef cg) {
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



// 功能键判定：空格/转换/地球/返回/删除/键盘切换/语言/听写/表情等 —— hideKeyCap 跳过它们

static void KSAttach(UIView *layoutStar) {
    if (!layoutStar || !ksEnabled) return;
    NSString *plane = nil;
    @try {
        id kp = [layoutStar valueForKey:@"keyplane"];
        plane = [kp valueForKey:@"name"];
    } @catch (__unused NSException *e) {}
    static int logs = 0;
    if (logs++ < 10) {
        KSLog(@"attach(obs) class=%@ plane=%@",
              KSClassOf(layoutStar), plane ?: @"(nil)");
    }
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
        KSLog(@"KeyboardSkin 1.9.2 init [%@] — enabled=%d hideStock=%d theme='%@' path=%@",
              NSProcessInfo.processInfo.processName, ksEnabled, ksHideStock, ksThemeName, ksThemePath);
        KSInstall();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSInstall(); });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &KSConfigChanged, CFSTR(KS_CHANGED), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
