// ============================================================
// 我的语音 · 解锁验证 (LocSim 算法)
//
// 解锁码 = SHA256(UDID) -> 取 15 字节 -> 映射到 56 字符集 -> 15 位解锁码
// 纯 SHA256，无 HMAC、无密钥、无 XOR。与 gen_license.py / 码生成器 完全一致，
// 所以开发者用任意一端生成的码都能在本机通过验证。
//
// 锁整个插件：未解锁时悬浮球仍可点，但只弹验证窗；面板/合成全部不可用，
// 直到输入正确解锁码。解锁状态存 NSUserDefaults(mv_license)，清 App 数据后重新锁。
// ============================================================
#import "MyVoiceCommon.h"
#import "MyVoicePanel.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>

// ---- 生成预期解锁码 (与 dylib_GC函数.m / gen_license.py 完全一致) ----
static NSString* __attribute__((noinline)) _MVGC(NSString* did) {
    const char* cs = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz";
    int cl = 56;  // 实际字符个数（去除了易混淆的 0 O 1 l I）
    const char* m = [did UTF8String];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(m, (CC_LONG)strlen(m), h);
    NSMutableString* code = [NSMutableString stringWithCapacity:15];
    for (int i = 0; i < 15; i++) {
        unsigned int v = ((unsigned int)h[i * 2 % CC_SHA256_DIGEST_LENGTH] << 8)
                        | (unsigned int)h[(i * 2 + 1) % CC_SHA256_DIGEST_LENGTH];
        [code appendFormat:@"%C", (unichar)cs[v % cl]];
    }
    return code;
}

// ---- 取本机 UDID (MGCopyAnswer 私有 API) ----
static NSString* __attribute__((noinline)) _MVUD(void) {
    static NSString* uid = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        void* h = dlopen("/System/Library/PrivateFrameworks/"
            "MobileKeyBag.framework/MobileKeyBag", RTLD_LAZY);
        if (h) {
            NSString* (*mg)(NSString*) = dlsym(h, "MGCopyAnswer");
            if (mg) uid = mg(@"UniqueDeviceID");
        }
        // 降级方案
        if (!uid) {
            id dev = [UIDevice currentDevice];
            SEL s = NSSelectorFromString(@"uniqueIdentifier");
            if ([dev respondsToSelector:s]) {
                IMP imp = [dev methodForSelector:s];
                uid = ((id(*)(id,SEL))imp)(dev, s);
            }
        }
        if (!uid) uid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        if (!uid) uid = @"unknown";
    });
    return uid;
}

// ---- 找最上层 VC (兼容 iOS13+ 多 scene) ----
static UIViewController* __attribute__((noinline)) _MVTopVC(void) {
    UIViewController* (^topOf)(UIViewController*) = ^UIViewController*(UIViewController* c){
        while (c.presentedViewController) c = c.presentedViewController;
        if ([c isKindOfClass:[UINavigationController class]])
            c = ((UINavigationController*)c).visibleViewController ?: c;
        else if ([c isKindOfClass:[UITabBarController class]])
            c = ((UITabBarController*)c).selectedViewController ?: c;
        return c;
    };
    for (UIScene* sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* w in ((UIWindowScene*)sc).windows) {
            if (w.rootViewController) return topOf(w.rootViewController);
        }
    }
    UIWindow* kw = UIApplication.sharedApplication.keyWindow;
    if (kw.rootViewController) return topOf(kw.rootViewController);
    return nil;
}

// ---- 解锁状态 (存 NSUserDefaults, key mv_license) ----
BOOL MVUnlocked(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"mv_license"];
}
static void _MVSetUnlocked(BOOL v) {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setBool:v forKey:@"mv_license"];
    [d synchronize];
}

// ---- 验证弹窗 ----
static NSString* _mv_license_hint = nil;
void MVShowLicenseAlert(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ MVShowLicenseAlert(); }); return; }
    NSString* did = _MVUD();
    UIViewController* top = _MVTopVC();
    if (!top) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ MVShowLicenseAlert(); });
        return;
    }
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"我的语音 · 解锁验证"
        message:[NSString stringWithFormat:
            @"本机 UDID：\n%@\n\n%@", did,
            _mv_license_hint ?: @"把 UDID 发给开发者生成解锁码，输入后即可使用全部功能。"]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField* tf){
        tf.placeholder = @"输入 15 位解锁码";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"复制 UDID" style:UIAlertActionStyleDefault handler:^(UIAlertAction* _){
        [UIPasteboard generalPasteboard].string = did;
        _mv_license_hint = nil;
        MVShowLicenseAlert();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"确认解锁" style:UIAlertActionStyleDefault handler:^(UIAlertAction* _){
        UITextField* tf = a.textFields.firstObject;
        NSString* input = [tf.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString* expect = _MVGC(did);
        if (input.length && [input isEqualToString:expect]) {
            _MVSetUnlocked(YES);
            MVLog(@"[license] 解锁成功");
            _mv_license_hint = nil;
            // 解锁后打开面板
            [[MyVoicePanel shared] togglePanel];
        } else {
            _mv_license_hint = [NSString stringWithFormat:@"解锁码无效，预期：%@", expect];
            MVShowLicenseAlert();
        }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(UIAlertAction* _){
        _mv_license_hint = nil;
    }]];
    [top presentViewController:a animated:YES completion:nil];
}
