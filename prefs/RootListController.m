#import "RootListController.h"

#define KS_DOMAIN @"com.ning.keyboardskin"
static NSString * const kKSDomain = @"com.ning.keyboardskin";
#define KS_CHANGED @"com.ning.keyboardskin.changed"
#define KS_DIR @"/var/mobile/Library/KeyboardSkin"
#define KS_THEMES @"/var/mobile/Library/KeyboardSkin/Themes"

@implementation KeyboardSkinRootListController

-(instancetype)init {
    if ((self = [super init])) self.title = @"键盘皮肤";
    return self;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"键盘皮肤";
    [[NSFileManager defaultManager] createDirectoryAtPath:KS_THEMES
                              withIntermediateDirectories:YES attributes:nil error:NULL];
}

-(id)preferencesPlistName { return @"Root"; }

-(id)specifiers {
    if (!_specifiers) _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    return _specifiers;
}

-(id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: KS_DOMAIN;
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
    if (v) return (__bridge_transfer id)v;
    return [specifier propertyForKey:@"default"];
}

-(void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: KS_DOMAIN;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)KS_CHANGED, NULL, NULL, true);
}

#pragma mark - 帮助

-(void)ksAlert:(NSString *)title message:(NSString *)msg copyPath:(NSString *)path {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (path.length) {
        [a addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
            UIPasteboard.generalPasteboard.string = path;
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *p = self;
    while (p.presentedViewController) p = p.presentedViewController;
    [p presentViewController:a animated:YES completion:nil];
}

-(NSArray<NSString *> *)ksThemeNames {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:KS_THEMES error:NULL]) {
        if ([item hasPrefix:@"."]) continue;
        NSString *full = [KS_THEMES stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] && isDir) [out addObject:item];
    }
    return out;
}

-(void)pickTheme:(PSSpecifier *)specifier {
    NSArray *names = [self ksThemeNames];
    BOOL hasSingle = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/KeyboardSkin/background.png"];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择主题" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (!names.count && !hasSingle) {
        sheet.message = @"还没发现主题。\n把图片放到 /var/mobile/Library/KeyboardSkin/background.png，或建一个 Themes/主题名/ 文件夹。";
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"自动（第一个主题 / 单图）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [self ksWriteTheme:@""];
    }]];
    for (NSString *n in names) {
        [sheet addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self ksWriteTheme:n];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    }
    UIViewController *p = self;
    while (p.presentedViewController) p = p.presentedViewController;
    [p presentViewController:sheet animated:YES completion:nil];
}

-(void)ksWriteTheme:(NSString *)name {
    CFPreferencesSetAppValue(CFSTR("ActiveTheme"), (__bridge CFPropertyListRef)name,
                             (__bridge CFStringRef)KS_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)KS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)KS_CHANGED, NULL, NULL, true);
    [self reloadSpecifiers];
    [self ksAlert:@"已选择" message:name.length ? name : @"自动（第一个主题 / 单图）" copyPath:nil];
}

-(void)openFolder:(PSSpecifier *)specifier {
    [[NSFileManager defaultManager] createDirectoryAtPath:KS_THEMES withIntermediateDirectories:YES attributes:nil error:NULL];
    NSArray *candidates = @[
        [NSString stringWithFormat:@"filza://view%@", KS_THEMES],
        [NSString stringWithFormat:@"shareddocuments://%@", KS_THEMES],
    ];
    [self ksOpenURLs:candidates index:0];
}

-(void)ksOpenURLs:(NSArray *)urls index:(NSUInteger)i {
    if (i >= urls.count) {
        [self ksAlert:@"主题目录" message:[NSString stringWithFormat:@"没能打开文件管理器，请用 Filza 进入：\n%@", KS_THEMES] copyPath:KS_THEMES];
        return;
    }
    NSURL *u = [NSURL URLWithString:urls[i]];
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:^(BOOL ok) {
        if (!ok) [self ksOpenURLs:urls index:i+1];
    }];
}

-(void)listThemes:(PSSpecifier *)specifier {
    NSMutableString *m = [NSMutableString stringWithString:@""];
    BOOL single = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/KeyboardSkin/background.png"];
    if (single) [m appendString:@"• background.png（单图）\n"];
    NSArray *names = [self ksThemeNames];
    for (NSString *n in names) {
        NSUInteger c = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:
            [KS_THEMES stringByAppendingPathComponent:n] error:NULL].count;
        [m appendFormat:@"• %@（%lu 项）\n", n, (unsigned long)c];
    }
    if (!m.length) [m appendString:@"（还没发现任何主题）"];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kKSDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("ActiveTheme"), (__bridge CFStringRef)kKSDomain);
    NSString *cur = v ? [(__bridge id)v copy] : nil;
    if (v) CFRelease(v);
    [m appendFormat:@"\n当前：%@", cur.length ? cur : @"自动"];
    [self ksAlert:@"已发现" message:m copyPath:KS_THEMES];
}

-(void)disableSkin:(PSSpecifier *)specifier {
    CFPreferencesSetAppValue(CFSTR("Enabled"), (__bridge CFPropertyListRef)@NO,
                             (__bridge CFStringRef)kKSDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kKSDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)KS_CHANGED, NULL, NULL, true);
    [self reloadSpecifiers];
    [self ksAlert:@"已停用" message:@"皮肤已关闭，重新弹出键盘恢复系统外观。重新打开「启用」即可恢复皮肤。" copyPath:nil];
}

-(void)respring:(PSSpecifier *)specifier {
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/killall", "killall", "-9", "SpringBoard", (char *)NULL);
        _exit(0);
    }
}

@end
