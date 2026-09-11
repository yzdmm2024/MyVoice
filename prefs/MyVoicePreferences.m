#import <Preferences/Preferences.h>

// tweak 侧用同一个域读取（微信进程内）。
static NSString *const kMyVoiceDomain  = @"com.yzdmm2024.myvoice";
// 跨进程通知：设置改动后让微信里的面板立刻生效。
static NSString *const kMyVoiceChanged = @"com.yzdmm2024.myvoice/settings";

@interface MyVoicePrefsListController : PSListController
@end

@implementation MyVoicePrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        // 面板布局在 bundle 内的 Root.plist（items 数组）。
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - 读写共享域（默认实现只会写 Settings 自己的域，微信读不到）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return nil;
    // ① 共享 suite（与 tweak 侧 [[NSUserDefaults alloc] initWithSuiteName:] 一致）
    id v = [[[NSUserDefaults alloc] initWithSuiteName:kMyVoiceDomain] objectForKey:key];
    // ② cfprefsd 域兜底
    if (!v) {
        CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                         (__bridge CFStringRef)kMyVoiceDomain);
        if (cv) v = CFBridgingRelease(cv);
    }
    return v ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    // 两处都写，保证微信进程里两种读法都拿得到
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kMyVoiceDomain];
    [d setObject:value forKey:key];
    [d synchronize];

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kMyVoiceDomain);
    CFPreferencesAppSynchronize((CFStringRef)kMyVoiceDomain);

    // Darwin 通知（跨进程；NSNotificationCenter 出不了本进程）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kMyVoiceChanged,
                                         NULL, NULL, true);
}

@end
