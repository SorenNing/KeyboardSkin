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
    if (lines > 6000) return;
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
    ksCornerRadius = (CGFloat)KSInt(@"CornerRadius", 0);
    ksHideKeyCaps = KSBool(@"HideKeyCaps", NO);
    ksFillMode = KSInt(@"FillMode", 0);
    ksScale = (CGFloat)KSInt(@"BgScale", 100) / 100.0;
    ksOffsetY = (CGFloat)KSInt(@"BgOffsetY", 0);
    NSString *t = KSStr(@"ActiveTheme");
    if (![ksThemeName isEqualToString:t]) { ksThemeName = t; KSLog(@"prefs theme='%@'", t); }
    KSResolveTheme();
}

#pragma mark - keyplane → 键名

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

// keyplane 名 -> 键面图层键名（Laetus 主题命名）
static NSString *KSKeyPlaneImageName(NSString *plane) {
    if (!plane.length) return nil;
    if ([plane isEqualToString:@"small-letters"] || [plane isEqualToString:@"capital-letters"]) return @"KeyboardLettersKeyPlane";
    if ([plane isEqualToString:@"numbers-and-punctuation"] ||
        [plane isEqualToString:@"numbers-and-punctuation-alternative"]) return @"KeyboardNumbersKeyPlane";
    if ([plane hasSuffix:@"-pad"]) return @"KeyboardNumberPadKeyPlane";
    return nil;   // emoji / dictation 等没有键面图
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
    // 单图兜底
    if ([fm fileExistsAtPath:@KS_SINGLE]) {
        UIImage *img = KSLoad(@KS_SINGLE);
        if (img) { ksCache[ck] = img; KSLog(@"img: background.png (single)"); return img; }
    }
    return nil;
}

#pragma mark - 图层处理

static const char kKSAssocBackground = '\0';
static const char kKSAssocSignature = '\0';

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


static void KSAttachLate(UIView *layoutStar);

static void KSAttach(UIView *layoutStar) {
    if (!layoutStar || !ksEnabled || !ksThemePath) return;
    UIView *container = layoutStar.superview ?: layoutStar;
    if (!container) return;

    BOOL landscape = UIScreen.mainScreen.bounds.size.width > UIScreen.mainScreen.bounds.size.height;
    NSString *plane = KSLastPlaneName();
    NSString *bgKey = @"KeyboardMainBG";

    UIImage *bgImg = KSImageForKey(bgKey, landscape);
    if (!bgImg) {
        static BOOL miss = NO;
        if (!miss) { miss = YES; KSLog(@"NO IMAGE %@ in %@", bgKey, ksThemePath.lastPathComponent); }
        return;
    }

    // 1) 兜底背景视图（container index 0）
    UIImageView *iv = objc_getAssociatedObject(container, &kKSAssocBackground);
    if (!iv) {
        iv = [[UIImageView alloc] init];
        iv.userInteractionEnabled = NO;
        iv.clipsToBounds = YES;
        objc_setAssociatedObject(container, &kKSAssocBackground, iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect kf = layoutStar.frame;
    iv.transform = CGAffineTransformIdentity;
    iv.frame = kf;
    if (ksScale != 1.0) iv.transform = CGAffineTransformMakeScale(ksScale, ksScale);
    iv.center = CGPointMake(CGRectGetMidX(kf), CGRectGetMidY(kf) + kf.size.height * (ksOffsetY / 100.0));
    iv.contentMode = (ksFillMode == 1) ? UIViewContentModeScaleAspectFit
                   : (ksFillMode == 2) ? UIViewContentModeScaleToFill
                   : (ksFillMode == 3) ? UIViewContentModeCenter
                                       : UIViewContentModeScaleAspectFill;
    if (iv.superview != container) [container insertSubview:iv atIndex:0];
    iv.image = bgImg;
    iv.alpha = 1.0;
    [CATransaction commit];

    // 2) keyplane 内的整键面贴图层：按 contents 方差分类替换
    NSMutableArray *layers = [NSMutableArray array];
    for (UIView *v in layoutStar.subviews) {
        if (![KSClassOf(v) containsString:@"Keyplane"]) continue;
        for (UIView *lv in v.subviews) {
            NSString *cn = KSClassOf(lv);
            if ([cn containsString:@"SplitImageView"] && lv.frame.size.width >= layoutStar.bounds.size.width * 0.9) {
                [layers addObject:lv];
            } else if ([cn containsString:@"KeyView"]) {
                if (ksCornerRadius > 0) {
                    lv.layer.cornerRadius = ksCornerRadius;
                    lv.layer.masksToBounds = YES;
                }
                if (ksHideKeyCaps) {
                    SEL hk = NSSelectorFromString(@"hideKeyCap:");
                    if ([lv respondsToSelector:hk]) ((void (*)(id, SEL, BOOL))objc_msgSend)(lv, hk, YES);
                }
            }
        }
    }

    NSMutableString *detail = [NSMutableString string];
    UIView *bgLayer = nil, *planeLayer = nil;
    double minVar = 1e18, maxVar = -1;
    for (UIView *lv in layers) {
        CGImageRef cg = KSContentCGImage(lv);
        double var = KSVarianceOfCGImage(cg);
        [detail appendFormat:@"[%@ var=%.0f] ", KSClassOf(lv), var];
        if (var >= 0) {
            if (var < minVar) { minVar = var; bgLayer = lv; }
            if (var > maxVar) { maxVar = var; planeLayer = lv; }
        }
    }

    NSString *plKey = KSKeyPlaneImageName(plane);
    UIImage *planeImg = plKey ? KSImageForKey(plKey, landscape) : nil;

    if (bgLayer && bgImg) {
        bgLayer.layer.contents = (__bridge id)bgImg.CGImage;
        bgLayer.layer.contentsGravity = kCAGravityResizeAspectFill;
        bgLayer.layer.contentsScale = UIScreen.mainScreen.scale;
    }
    if (planeLayer && planeLayer != bgLayer && planeImg) {
        planeLayer.layer.contents = (__bridge id)planeImg.CGImage;
        planeLayer.layer.contentsGravity = kCAGravityResizeAspectFill;
        planeLayer.layer.contentsScale = UIScreen.mainScreen.scale;
    }

    // 3) 顶部预测栏背景（灰色横条）
    UIEdgeInsets pad = UIEdgeInsetsZero;
    for (UIView *v in layoutStar.subviews) {
        if (![KSClassOf(v) containsString:@"Keyplane"]) {
            CGFloat hgt = v.frame.size.height;
            if (hgt >= 24 && hgt <= 90) {
                UIImage *pred = KSImageForKey(@"KeyboardPredictionBarBG", landscape);
                if (pred) {
                    UIImageView *pv = objc_getAssociatedObject(v, &kKSAssocBackground);
                    if (!pv) {
                        pv = [[UIImageView alloc] init];
                        pv.userInteractionEnabled = NO;
                        pv.clipsToBounds = YES;
                        pv.contentMode = UIViewContentModeScaleAspectFill;
                        objc_setAssociatedObject(v, &kKSAssocBackground, pv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    pv.frame = v.bounds;
                    if (pv.superview != v) [v insertSubview:pv atIndex:0];
                    pv.image = pred;
                    [CATransaction commit];
                    v.backgroundColor = UIColor.clearColor;
                    [detail appendFormat:@"[pred %@ %.0f] ", KSClassOf(v), hgt];
                }
            }
        }
    }
    (void)pad;

    KSLog(@"attach plane=%@ key=%@ layers=%lu bg=%@ plane=%@ minVar=%.0f maxVar=%.0f %@",
          plane ?: @"(nil)", KSKeyForPlane(plane), (unsigned long)layers.count,
          bgLayer ? KSClassOf(bgLayer) : @"(nil)",
          planeLayer ? KSClassOf(planeLayer) : @"(nil)", minVar, maxVar, detail);

    // contents 可能还没渲染好，稍后重试两次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ KSAttachLate(layoutStar); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ KSAttachLate(layoutStar); });
}

static void KSAttachLate(UIView *layoutStar) {
    @try {
        if (!ksEnabled || !ksThemePath || !layoutStar.superview) return;
        BOOL landscape = UIScreen.mainScreen.bounds.size.width > UIScreen.mainScreen.bounds.size.height;
        UIImage *bgImg = KSImageForKey(@"KeyboardMainBG", landscape);
        if (!bgImg) return;
        NSString *plane = KSLastPlaneName();
        NSString *plKey = KSKeyPlaneImageName(plane);
        UIImage *planeImg = plKey ? KSImageForKey(plKey, landscape) : nil;

        NSMutableArray *layers = [NSMutableArray array];
        for (UIView *v in layoutStar.subviews) {
            if (![KSClassOf(v) containsString:@"Keyplane"]) continue;
            for (UIView *lv in v.subviews) {
                if ([KSClassOf(lv) containsString:@"SplitImageView"] &&
                    lv.frame.size.width >= layoutStar.bounds.size.width * 0.9) [layers addObject:lv];
            }
        }
        UIView *bgLayer = nil, *planeLayer = nil;
        double minVar = 1e18, maxVar = -1;
        for (UIView *lv in layers) {
            double var = KSVarianceOfCGImage(KSContentCGImage(lv));
            if (var < 0) continue;
            if (var < minVar) { minVar = var; bgLayer = lv; }
            if (var > maxVar) { maxVar = var; planeLayer = lv; }
        }
        if (bgLayer) {
            bgLayer.layer.contents = (__bridge id)bgImg.CGImage;
            bgLayer.layer.contentsGravity = kCAGravityResizeAspectFill;
        }
        if (planeLayer && planeLayer != bgLayer && planeImg) {
            planeLayer.layer.contents = (__bridge id)planeImg.CGImage;
            planeLayer.layer.contentsGravity = kCAGravityResizeAspectFill;
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - Hooks

// setImage:cachedWidth:keyplane: —— Laetus 双图族方案
// 传入的 image 是系统渲染好的整键面贴图。用亮度方差区分它是哪一层：
//   低方差 = 背景层（模糊/纯色）      → 换成 KeyboardMainBG*
//   高方差 = 键面层（满是键帽造型）  → 换成 Keyboard*KeyPlane*
// 若主题没有键面图，则不放行替换，保证字母/键帽仍是系统的。
static IMP orig_setImage = NULL;
static void ks_setImage(UIView *self, SEL _cmd, UIImage *image, double width, id keyplane) {
    UIImage *out = image;
    @try {
        if (ksEnabled && ksThemePath && image) {
            CGRect f = self.bounds;
            if (f.size.width < UIScreen.mainScreen.bounds.size.width * 0.85) {
                ((void (*)(id, SEL, UIImage *, double, id))orig_setImage)(self, _cmd, image, width, keyplane);
                return;   // 小的是键位贴图，放行
            }
            NSString *plane = nil;
            @try { plane = [keyplane valueForKey:@"name"]; } @catch (__unused NSException *e) {}
            if (!plane.length) plane = KSLastPlaneName();
            BOOL landscape = UIScreen.mainScreen.bounds.size.width > UIScreen.mainScreen.bounds.size.height;

            double var = KSImageVariance(image);
            BOOL isBackground = (var < 600.0);

            UIImage *theme = nil;
            NSString *which = nil;
            if (isBackground) {
                theme = KSImageForKey(@"KeyboardMainBG", landscape);
                which = @"MainBG";
            } else {
                NSString *plKey = KSKeyPlaneImageName(plane);
                if (plKey) {
                    theme = KSImageForKey(plKey, landscape);
                    which = plKey;
                }
            }
            if (theme) {
                out = theme;
                static int logs = 0;
                if (logs++ < 24) KSLog(@"setImage %@ var=%.0f -> %@ (plane=%@)",
                                       isBackground ? @"BG" : @"PLANE", var, which, plane ?: @"(nil)");
            }
        }
    } @catch (NSException *e) { KSLog(@"exc setImage: %@", e); }
    ((void (*)(id, SEL, UIImage *, double, id))orig_setImage)(self, _cmd, out, width, keyplane);
}

static IMP orig_layoutSubviews = NULL;
static void ks_layoutSubviews(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))orig_layoutSubviews)(self, _cmd);
    @try {
        if (!ksEnabled || !ksThemePath) return;
        @try {
            NSString *pn = [self valueForKey:@"keyplaneName"];
            if (pn.length) ksLastPlane = pn;
        } @catch (__unused NSException *e) {}
        KSAttach(self);
    } @catch (NSException *e) { KSLog(@"exc layout: %@", e); }
}

static IMP orig_didChangeKeyplane = NULL;
static void ks_didChangeKeyplane(UIView *self, SEL _cmd, id ctx) {
    ((void (*)(id, SEL, id))orig_didChangeKeyplane)(self, _cmd, ctx);
    @try {
        if (!ksEnabled) return;
        NSString *plane = nil;
        @try { plane = [self valueForKey:@"keyplaneName"]; } @catch (__unused NSException *e) {}
        if (!plane.length) {
            @try { plane = [self valueForKey:@"_keyplaneName"]; } @catch (__unused NSException *e) {}
        }
        if (plane.length) ksLastPlane = plane;
        KSLog(@"keyplane: %@ (cached %@)", plane ?: @"(nil)", ksLastPlane ?: @"(nil)");
        objc_setAssociatedObject(self.superview, &kKSAssocSignature, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{ KSAttach(self); });
    } @catch (NSException *e) { KSLog(@"exc keyplane: %@", e); }
}

// 额外触发点：键盘第一次显示时
static IMP orig_showKeyboard = NULL;
static void ks_showKeyboard(UIView *self, SEL _cmd, id traits, id screen, id split) {
    ((void (*)(id, SEL, id, id, id))orig_showKeyboard)(self, _cmd, traits, screen, split);
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{ KSAttach(self); });
    } @catch (__unused NSException *e) {}
}

#pragma mark - 安装

static void KSConfigChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *p, CFDictionaryRef d) {
    KSReloadPrefs();
    KSLog(@"config changed: scale=%.2f offsetY=%.0f mode=%ld hideCaps=%d corner=%.0f",
          ksScale, ksOffsetY, (long)ksFillMode, ksHideKeyCaps, ksCornerRadius);
}

static void KSInstall(void) {
    Class star = NSClassFromString(@"UIKeyboardLayoutStar");
    if (!star) { KSLog(@"class missing"); return; }

    if (!orig_layoutSubviews && [star instancesRespondToSelector:@selector(layoutSubviews)]) {
        MSHookMessageEx(star, @selector(layoutSubviews), (IMP)ks_layoutSubviews, (IMP *)&orig_layoutSubviews);
        KSLog(@"hook: layoutSubviews");
    }
    if (!orig_didChangeKeyplane) {
        SEL s = NSSelectorFromString(@"_didChangeKeyplaneWithContext:");
        if ([star instancesRespondToSelector:s]) {
            MSHookMessageEx(star, s, (IMP)ks_didChangeKeyplane, (IMP *)&orig_didChangeKeyplane);
            KSLog(@"hook: _didChangeKeyplaneWithContext:");
        }
    }
    Class split = NSClassFromString(@"UIKBSplitImageView");
    if (split && !orig_setImage) {
        SEL ss = NSSelectorFromString(@"setImage:cachedWidth:keyplane:");
        if ([split instancesRespondToSelector:ss]) {
            MSHookMessageEx(split, ss, (IMP)ks_setImage, (IMP *)&orig_setImage);
            KSLog(@"hook: UIKBSplitImageView setImage:cachedWidth:keyplane: (size-gated)");
        }
    }
    if (!orig_showKeyboard) {
        SEL s = NSSelectorFromString(@"showKeyboardWithInputTraits:screenTraits:splitTraits:");
        if ([star instancesRespondToSelector:s]) {
            MSHookMessageEx(star, s, (IMP)ks_showKeyboard, (IMP *)&orig_showKeyboard);
            KSLog(@"hook: showKeyboardWithInputTraits:screenTraits:splitTraits:");
        }
    }
}

__attribute__((constructor))
static void KSInit(void) {
    @autoreleasepool {
        KSReloadPrefs();
        KSLog(@"KeyboardSkin 1.5.1 init [%@] — enabled=%d hideStock=%d theme='%@' path=%@",
              NSProcessInfo.processInfo.processName, ksEnabled, ksHideStock, ksThemeName, ksThemePath);
        KSInstall();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSInstall(); });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &KSConfigChanged, CFSTR(KS_CHANGED), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
