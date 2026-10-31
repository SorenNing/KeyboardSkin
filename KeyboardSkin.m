// 键盘皮肤（KeyboardSkin）— 系统键盘背景换皮肤
// 设计原则：只做一件事，且用最可靠的方式
//   1. hook UIKeyboardLayoutStar -layoutSubviews（UIView 必有方法，必触发）
//   2. 在键盘容器里插入自己的 UIImageView 当背景（insertSubview:atIndex:0）
//   3. 把系统的背景/模糊层 alpha 置 0（按类名匹配 Background/VisualEffect/Backdrop）
//   4. hook _didChangeKeyplaneWithContext: 跟踪 keyplane（换字母/数字/emoji 面时换图）
// 不用 setImage:cachedWidth:keyplane:（参数语义不明确，容易误伤键帽）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <CydiaSubstrate/CydiaSubstrate.h>

#define KS_DOMAIN  "com.ning.keyboardskin"
#define KS_CHANGED "com.ning.keyboardskin.changed"
#define KS_LOG     "/var/mobile/Library/KeyboardSkin.log"
#define KS_DIR     "/var/mobile/Library/KeyboardSkin"
#define KS_THEMES  "/var/mobile/Library/KeyboardSkin/Themes"
#define KS_SINGLE  "/var/mobile/Library/KeyboardSkin/background.png"

#pragma mark - 日志

static void KSLog(NSString *format, ...) {
    static NSInteger lines = -1;
    if (lines < 0) { lines = 0; unlink(KS_LOG); }
    if (lines > 4000) return;
    va_list args; va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *out = [NSString stringWithFormat:@"[ks %@] %@\n",
        [NSDate.date descriptionWithLocale:@"HH:mm:ss"], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@KS_LOG];
    if (!fh) {
        [@"" writeToFile:@KS_LOG atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        fh = [NSFileHandle fileHandleForWritingAtPath:@KS_LOG];
    }
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    lines++;
}

#pragma mark - 偏好

static BOOL ksEnabled = YES;
static BOOL ksHideStock = YES;
static NSString *ksThemeName = nil;
static NSString *ksThemePath = nil;
static NSInteger ksGen = 0;

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
        if (dirs.count) resolved = dirs.firstObject;
    }
    if (!resolved && [fm fileExistsAtPath:@KS_SINGLE]) resolved = @KS_DIR;   // 单图兜底

    if (resolved && ![resolved isEqualToString:ksThemePath]) {
        ksThemePath = resolved; ksGen++;
        KSLog(@"theme resolved -> %@ (gen %ld)", ksThemePath, (long)ksGen);
    } else if (!resolved && ksThemePath) {
        ksThemePath = nil; ksGen++;
        KSLog(@"theme cleared");
    }
}

static void KSReloadPrefs(void) {
    BOOL oldEn = ksEnabled;
    ksEnabled = KSBool(@"Enabled", YES);
    ksHideStock = KSBool(@"HideStock", YES);
    NSString *t = KSStr(@"ActiveTheme");
    if (![ksThemeName isEqualToString:t]) {
        ksThemeName = t;
        KSLog(@"prefs: theme='%@' enabled=%d hideStock=%d", ksThemeName, ksEnabled, ksHideStock);
    }
    KSResolveTheme();
    if (oldEn != ksEnabled) { ksGen++; KSLog(@"enabled -> %d", ksEnabled); }
}

#pragma mark - keyplane → 键名（照 Laetus keyplaneNameToKey: 表）

static NSString *KSKeyForPlane(NSString *name) {
    if (!name.length) return @"KeyboardMainBG";
    if ([name isEqualToString:@"small-letters"] || [name isEqualToString:@"capital-letters"]) return @"KeyboardMainBG";
    if ([name isEqualToString:@"numbers-and-punctuation"] || [name isEqualToString:@"numbers-and-punctuation-alternative"]) return @"KeyboardNumbersBG";
    if ([name isEqualToString:@"emoji-keyboard"]) return @"KeyboardEmojiBG";
    if ([name hasSuffix:@"-pad"]) return @"KeyboardNumberPadBG";
    if ([name isEqualToString:@"autofill"]) return @"KeyboardAutoFillBG";
    if ([name isEqualToString:@"picker"]) return @"KeyboardPickerBG";
    if ([name isEqualToString:@"dictation"]) return @"KeyboardDictationBG";
    return @"KeyboardMainBG";
}

#pragma mark - 图片查找

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
        KSLog(@"device height %.0fpt", pt);
    });
    return s;
}

static UIImage *KSImageAtPath(NSString *path) {
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    return [UIImage imageWithCGImage:raw.CGImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
}

static NSMutableDictionary *ksCache;

static UIImage *KSImageForKey(NSString *key, BOOL landscape) {
    if (!ksThemePath || !key.length) return nil;
    NSString *orient = landscape ? @"Landscape" : @"Portrait";
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@|gen%ld", key, orient, (long)ksGen];
    if (!ksCache) ksCache = [NSMutableDictionary new];
    UIImage *hit = ksCache[cacheKey];
    if (hit) return hit;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *h = KSHeightSuffix();
    NSArray *scales = @[@"@3x", @"@2x", @""];

    // 目录：主题根 + Images 子目录；单图模式只有根
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:ksThemePath];
    if (![ksThemePath isEqualToString:@KS_DIR]) {
        for (NSString *sub in @[@"Images", @"images", @"Image"]) {
            NSString *p = [ksThemePath stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) [dirs addObject:p];
        }
    }

    // 候选名：从最具体到最简
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *sc in scales) if (h) [names addObject:[NSString stringWithFormat:@"%@-%@-%@%@.png", key, orient, h, sc]];
    for (NSString *sc in scales) [names addObject:[NSString stringWithFormat:@"%@-%@%@.png", key, orient, sc]];
    for (NSString *sc in scales) if (h) [names addObject:[NSString stringWithFormat:@"%@-%@%@.png", key, h, sc]];
    for (NSString *sc in scales) [names addObject:[NSString stringWithFormat:@"%@%@.png", key, sc]];
    // 屏高兜底
    if ([h isEqualToString:@"932h"]) {
        for (NSString *sc in scales) [names addObject:[NSString stringWithFormat:@"%@-%@-896h%@.png", key, orient, sc]];
    } else if ([h isEqualToString:@"844h"]) {
        for (NSString *sc in scales) [names addObject:[NSString stringWithFormat:@"%@-%@-812h%@.png", key, orient, sc]];
    }

    for (NSString *dir in dirs) {
        for (NSString *n in names) {
            NSString *p = [dir stringByAppendingPathComponent:n];
            if ([fm fileExistsAtPath:p]) {
                UIImage *img = KSImageAtPath(p);
                if (img) {
                    ksCache[cacheKey] = img;
                    KSLog(@"image: %@/%@", dir.lastPathComponent, n);
                    return img;
                }
            }
        }
        // 前缀兜底（键名开头 + 方向匹配）
        NSString *best = nil;
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
            if (![f hasPrefix:key]) continue;
            if (orient.length && ![f containsString:orient]) continue;
            if (!best || f.length > best.length) best = f;
        }
        if (best) {
            UIImage *img = KSImageAtPath([dir stringByAppendingPathComponent:best]);
            if (img) {
                ksCache[cacheKey] = img;
                KSLog(@"image(prefix): %@/%@", dir.lastPathComponent, best);
                return img;
            }
        }
    }
    return nil;
}

#pragma mark - 视图装配

static const char kKSAssocBackground = '\0';
static const char kKSAssocSignature = '\0';

// 递归把"系统背景层"透明掉（只看类名特征，深度受限）
static void KSFadeStockBackground(UIView *root, int depth) {
    if (!root || depth > 4) return;
    for (UIView *v in root.subviews) {
        NSString *cn = NSStringFromClass([v class]);
        BOOL isBg = [cn containsString:@"Background"] || [cn containsString:@"VisualEffect"] ||
                    [cn containsString:@"Backdrop"];
        if (isBg) {
            if (v.alpha != 0) {
                v.alpha = ksHideStock ? 0.0 : 1.0;
            }
        }
        KSFadeStockBackground(v, depth + 1);
    }
}

// 打印键盘层级（前 3 次，帮助诊断）
static void KSDumpHierarchy(UIView *v, int depth, NSMutableString *out) {
    if (depth > 3) return;
    for (UIView *s in v.subviews) {
        [out appendFormat:@"%@%@ %@ %d subviews\n",
            [@"" stringByPaddingToLength:(depth*2) withString:@" " startingAtIndex:0],
            NSStringFromClass([s class]),
            NSStringFromCGRect(s.frame), (int)s.subviews.count];
        KSDumpHierarchy(s, depth + 1, out);
    }
}

static void KSAttachToLayout(UIView *layoutStar) {
    if (!layoutStar || !ksEnabled || !ksThemePath) return;

    UIView *container = layoutStar.superview ?: layoutStar;
    if (!container) return;

    // keyplane 名（公开 property，KVC 兜底）
    NSString *plane = nil;
    @try { plane = [layoutStar valueForKey:@"keyplaneName"]; } @catch (__unused NSException *e) {}
    BOOL landscape = UIScreen.mainScreen.bounds.size.width > UIScreen.mainScreen.bounds.size.height;
    NSString *key = KSKeyForPlane(plane);
    NSString *sig = [NSString stringWithFormat:@"%@|%d|gen%ld|%.0fx%.0f", key, landscape, (long)ksGen,
                     layoutStar.bounds.size.width, layoutStar.bounds.size.height];

    UIImage *img = KSImageForKey(key, landscape);
    if (!img) {
        static BOOL missLogged = NO;
        if (!missLogged) {
            missLogged = YES;
            KSLog(@"NO IMAGE for %@ (%@) in %@", key, landscape ? @"L" : @"P", ksThemePath.lastPathComponent);
        }
        return;
    }

    UIImageView *iv = objc_getAssociatedObject(container, &kKSAssocBackground);
    if (!iv) {
        iv = [[UIImageView alloc] init];
        iv.userInteractionEnabled = NO;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        objc_setAssociatedObject(container, &kKSAssocBackground, iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        KSLog(@"created background view for container %@", NSStringFromClass([container class]));
    }

    NSString *last = objc_getAssociatedObject(container, &kKSAssocSignature);
    BOOL needImage = ![last isEqualToString:sig] || iv.image == nil;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    iv.frame = layoutStar.frame;
    if (iv.superview != container) [container insertSubview:iv atIndex:0];
    iv.alpha = 1.0;
    if (needImage) {
        iv.image = img;
        objc_setAssociatedObject(container, &kKSAssocSignature, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);
        KSLog(@"attached: container=%@ layout=%@ key=%@ plane=%@ frame=%@ img=%.0fx%.0f",
              NSStringFromClass([container class]), NSStringFromClass([layoutStar class]),
              key, plane ?: @"(nil)", NSStringFromCGRect(iv.frame),
              img.size.width, img.size.height);
    }
    [CATransaction commit];

    if (ksHideStock) {
        KSFadeStockBackground(container, 0);
        KSFadeStockBackground(layoutStar, 0);
    }
}

#pragma mark - Hooks

static IMP orig_layoutSubviews = NULL;
static void ks_hook_layoutSubviews(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))orig_layoutSubviews)(self, _cmd);
    @try {
        if (!ksEnabled || !ksThemePath) return;
        static int fired = 0;
        fired++;
        if (fired <= 3) {
            NSMutableString *dump = [NSMutableString string];
            [dump appendFormat:@"--- hierarchy #%d (container=%@) ---\n", fired,
                NSStringFromClass([self.superview class])];
            KSDumpHierarchy(self.superview ?: self, 1, dump);
            KSLog(@"%@", dump);
        }
        KSAttachToLayout(self);
    } @catch (NSException *e) { KSLog(@"exc layout: %@", e); }
}

static IMP orig_didChangeKeyplane = NULL;
static void ks_hook_didChangeKeyplane(UIView *self, SEL _cmd, id context) {
    ((void (*)(id, SEL, id))orig_didChangeKeyplane)(self, _cmd, context);
    @try {
        if (!ksEnabled) return;
        NSString *plane = nil;
        @try { plane = [self valueForKey:@"keyplaneName"]; } @catch (__unused NSException *e) {}
        KSLog(@"keyplane changed: %@", plane ?: @"(nil)");
        dispatch_async(dispatch_get_main_queue(), ^{
            KSAttachToLayout(self);
        });
    } @catch (NSException *e) { KSLog(@"exc keyplane: %@", e); }
}

#pragma mark - 安装

static void KSConfigChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *p, CFDictionaryRef d) {
    KSReloadPrefs();
    KSLog(@"config changed");
}

static void KSInstallHooks(void) {
    Class star = NSClassFromString(@"UIKeyboardLayoutStar");
    if (!star) { KSLog(@"UIKeyboardLayoutStar missing"); return; }

    if (!orig_layoutSubviews) {
        SEL sel = @selector(layoutSubviews);
        if ([star instancesRespondToSelector:sel]) {
            MSHookMessageEx(star, sel, (IMP)ks_hook_layoutSubviews, (IMP *)&orig_layoutSubviews);
            KSLog(@"hook: UIKeyboardLayoutStar layoutSubviews");
        }
    }
    if (!orig_didChangeKeyplane) {
        SEL sel = NSSelectorFromString(@"_didChangeKeyplaneWithContext:");
        if ([star instancesRespondToSelector:sel]) {
            MSHookMessageEx(star, sel, (IMP)ks_hook_didChangeKeyplane, (IMP *)&orig_didChangeKeyplane);
            KSLog(@"hook: _didChangeKeyplaneWithContext:");
        }
    }
}

__attribute__((constructor))
static void KSInitialize(void) {
    @autoreleasepool {
        KSReloadPrefs();
        KSLog(@"KeyboardSkin init — enabled=%d hideStock=%d theme='%@' path=%@",
              ksEnabled, ksHideStock, ksThemeName, ksThemePath);
        KSInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSInstallHooks(); });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &KSConfigChanged,
                                        CFSTR(KS_CHANGED), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
