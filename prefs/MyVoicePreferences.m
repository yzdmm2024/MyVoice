#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>

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

#pragma mark - 取当前面板里的值（走上面的读逻辑，未提交的输入先落盘）

- (NSString*)mv_valueForKey:(NSString*)key {
    for (PSSpecifier *sp in self.specifiers) {
        if ([[sp propertyForKey:@"key"] isEqualToString:key]) {
            id v = [self readPreferenceValue:sp];
            if ([v isKindOfClass:[NSString class]]) return [v stringByTrimmingCharactersInSet:
                                                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (v) return [[v description] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return @"";
}

#pragma mark - 结果弹窗 + 按钮状态

- (void)mv_alert:(BOOL)ok title:(NSString*)title message:(NSString*)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"%@ %@", ok ? @"✅" : @"❌", title]
                             message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

- (void)mv_setBusy:(PSSpecifier*)sp text:(NSString*)text {
    if (!sp) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *orig = [sp propertyForKey:@"mv_label"];
        if (!text) {
            if (orig) [sp setProperty:orig forKey:@"label"];
        } else {
            if (!orig) [sp setProperty:[sp propertyForKey:@"label"] ?: @"测试" forKey:@"mv_label"];
            [sp setProperty:text forKey:@"label"];
        }
        [self reloadSpecifier:sp];
    });
}

// 按 plist 里的 action 名找按钮对应的 specifier（方法故意做成无参，避免
// PSButtonCell 传参/不传参两种调用方式不一致导致的崩溃）。
- (PSSpecifier*)mv_specifierForAction:(NSString*)name {
    for (PSSpecifier *sp in self.specifiers) {
        id a = [sp propertyForKey:@"action"];
        if ([a isKindOfClass:[NSString class]] && [a isEqualToString:name]) return sp;
    }
    return nil;
}

// Endpoint 容错：用户常把 https:// 或 bucket 前缀也粘进来
static NSString* MVCleanHost(NSString *h) {
    h = [h stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([h hasPrefix:@"https://"]) h = [h substringFromIndex:8];
    if ([h hasPrefix:@"http://"])  h = [h substringFromIndex:7];
    while ([h hasSuffix:@"/"]) h = [h substringToIndex:h.length - 1];
    NSRange dot = [h rangeOfString:@"."];
    // 形如 mybucket.oss-cn-beijing.aliyuncs.com 时去掉前面的 bucket
    if (dot.location != NSNotFound && [h hasPrefix:@"oss"] == NO) {
        NSString *rest = [h substringFromIndex:dot.location + 1];
        if ([rest hasPrefix:@"oss"]) h = rest;
    }
    return h;
}

#pragma mark - 测试 DashScope API Key

- (void)testAPIKey {
    [self.view endEditing:YES];
    PSSpecifier *sp = [self mv_specifierForAction:@"testAPIKey"];
    NSString *key = [self mv_valueForKey:@"apiKey"];
    if (!key.length) {
        [self mv_alert:NO title:@"还没填 API Key" message:@"请先在上方「API Key」里粘贴 sk- 开头的密钥。"];
        return;
    }
    NSString *ws = [self mv_valueForKey:@"workspace"];
    NSString *host = ws.length
        ? [NSString stringWithFormat:@"https://%@.cn-beijing.maas.aliyuncs.com/api/v1", ws]
        : @"https://dashscope.aliyuncs.com/api/v1";

    [self mv_setBusy:sp text:@"测试中…"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[host stringByAppendingString:@"/services/audio/tts/customization"]]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 20;

    __weak typeof(self) wself = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        __strong typeof(wself) self = wself;
        if (!self) return;
        [self mv_setBusy:sp text:nil];
        if (e) {
            [self mv_alert:NO title:@"网络不通"
                  message:[NSString stringWithFormat:@"%@\n\n请确认手机能上网（没开代理/VPN 拦截）。",
                           e.localizedDescription]];
            return;
        }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        NSString *body = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
        if (body.length > 300) body = [[body substringToIndex:300] stringByAppendingString:@"…"];

        if (code == 200 || code == 400) {
            [self mv_alert:YES title:@"API Key 有效"
                  message:[NSString stringWithFormat:
                      @"接口可以正常访问，Key 没问题。\n\n（这是故意发的不完整请求，回 400 是正常的）\n请求地址：%@",
                      host]];
        } else if (code == 401) {
            [self mv_alert:NO title:@"API Key 无效（401）"
                  message:@"请确认 sk- 后面没漏字符；或到 bailian.console.aliyun.com 重新创建一个（只显示一次）。"];
        } else if (code == 403) {
            [self mv_alert:NO title:@"被拒绝（403）"
                  message:[NSString stringWithFormat:
                      @"常见原因：\n① 百炼服务没开通\n② 控制台右上角地域不是「华北2 北京」\n"
                      @"③ 用了子业务空间，但 workspace 没填\n\n%@", body]];
        } else {
            [self mv_alert:NO title:[NSString stringWithFormat:@"意外状态 %ld", (long)code] message:body];
        }
    }] resume];
}

#pragma mark - 测试 OSS（只验证「地址 + 公共读」，不校验 AK/SK）

- (void)testOSS {
    [self.view endEditing:YES];
    PSSpecifier *sp = [self mv_specifierForAction:@"testOSS"];
    NSString *bucket = [self mv_valueForKey:@"ossBucket"];
    NSString *host   = [self mv_valueForKey:@"ossHost"];
    NSString *ak     = [self mv_valueForKey:@"ossAk"];
    NSString *sk     = [self mv_valueForKey:@"ossSk"];
    if (!bucket.length || !host.length) {
        [self mv_alert:NO title:@"先填 Bucket 和 Endpoint"
              message:@"这两项必填。Bucket 是你在 OSS 控制台建的那个名字；Endpoint 形如 oss-cn-beijing.aliyuncs.com（不带 https://）。"];
        return;
    }
    host = MVCleanHost(host);
    NSString *probe = [NSString stringWithFormat:@"myvoice-probe-%@.txt", [[NSUUID UUID] UUIDString]];
    NSString *url = [NSString stringWithFormat:@"https://%@.%@/%@", bucket, host, probe];

    [self mv_setBusy:sp text:@"测试中…"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 20;

    __weak typeof(self) wself = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        __strong typeof(wself) self = wself;
        if (!self) return;
        [self mv_setBusy:sp text:nil];
        NSString *akNote = (ak.length && sk.length)
            ? @"\n\n（AK/SK 已填写，但本测试不校验签名，克隆时才能验证）"
            : @"\n\n⚠️ AccessKey / Secret 还是空的，克隆时会失败。";
        if (e) {
            [self mv_alert:NO title:@"网络不通" message:e.localizedDescription];
            return;
        }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        NSString *body = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
        BOOL noBucket  = [body containsString:@"NoSuchBucket"];
        BOOL wrongEp   = [body containsString:@"SecondLevelDomainForbidden"] || [body containsString:@"WrongEndpoint"];

        if (code == 404 && [body containsString:@"NoSuchKey"]) {
            [self mv_alert:YES title:@"地址正确、公共读已开"
                  message:[NSString stringWithFormat:@"Bucket 名和 Endpoint 都对，匿名也能访问。%@", akNote]];
        } else if (code == 404 && noBucket) {
            [self mv_alert:NO title:@"找不到这个 Bucket"
                  message:[NSString stringWithFormat:@"Bucket 名字拼错了，或它不在 Endpoint 对应的地域。\nBucket=%@\nEndpoint=%@", bucket, host]];
        } else if (code == 403) {
            [self mv_alert:NO title:@"访问被拒（403）"
                  message:[NSString stringWithFormat:
                      @"Bucket 存在，但不是公共读。到 OSS 控制台：\n① 关闭「阻止公共访问」\n② 读写权限改成「公共读」\n%@",
                      wrongEp ? @"\n另外 Endpoint 可能不是外网节点（别用内网/加速域名）。" : @""]];
        } else {
            [self mv_alert:NO title:[NSString stringWithFormat:@"意外状态 %ld", (long)code]
                  message:body.length ? body : @"请检查 Bucket / Endpoint 是否写反了。"];
        }
    }] resume];
}

@end
