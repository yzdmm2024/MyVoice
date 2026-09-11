#import <Foundation/Foundation.h>

// 统一日志前缀，方便在设备 syslog 里过滤调试。
#define MVLog(fmt, ...) NSLog(@"[MyVoice] " fmt, ##__VA_ARGS__)

// 设置域（设置面板 + tweak 共用）
#define MV_PREFS_ID @"com.yzdmm2024.myvoice"
// 跨进程通知名（设置面板改完发，微信里的面板监听）
#define MV_CHANGED_NOTIFY "com.yzdmm2024.myvoice/settings"

// 微信语音标准：24kHz / 单声道 / S16。SILK 编码 + 直发都按这个来。
#define MV_WECHAT_SR 24000.0

static inline NSUserDefaults* MVPrefs(void) {
    static NSUserDefaults *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:MV_PREFS_ID]; });
    return d;
}

// ---- 跨进程共享配置的真实落点（rootless 越狱）----
// 设置面板跑在 Settings 进程里，它写出的域配置实际落在 jbroot 内：
//     /var/jb/var/mobile/Library/Preferences/com.yzdmm2024.myvoice.plist
// 而 App 进程（微信）内的 cfprefsd 会把这个域映射到**自己的容器**，所以
//   【必须直接读上面那个文件】，CFPreferences 能读到才是意外。
// 实测（iPhone 12 Pro / iOS 16.6.1 / RootHide，frida 注入 WeChat 验证）：
//   · /var/jb/var/mobile/Library/Preferences/ 目录与文件：可读、可解析 ✅
//   · /var/mobile/Library/Preferences/ 整个目录：不可读（Operation not permitted）❌
//   · CFPreferencesCopyAppValue(本域)：null ❌（容器映射）
//   · initWitSuiteName: 读到的其实是 App 自己的 standard defaults ❌
#define MV_JBROOT_PREFS @"/var/jb/var/mobile/Library/Preferences/"
#define MV_GLOBAL_PREFS @"/var/mobile/Library/Preferences/"

// 读取越狱共享域的 plist（带 mtime 缓存：MVGet 调用很频繁，不能每次都 stat+解析）
static inline NSDictionary* MVSharedPrefs(void) {
    static NSDictionary *cache = nil;
    static NSDate *cacheMTime = nil;
    static NSString *cachePath = nil;
    NSArray *cands = @[
        [MV_JBROOT_PREFS stringByAppendingFormat:@"%@.plist", MV_PREFS_ID],
        [MV_GLOBAL_PREFS stringByAppendingFormat:@"%@.plist", MV_PREFS_ID]
    ];
    for (NSString *p in cands) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!attrs) continue;
        NSDate *mt = attrs[NSFileModificationDate];
        if (cache && cachePath && [cachePath isEqualToString:p] && [mt isEqualToDate:cacheMTime]) return cache;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]]) {
            cache = d; cacheMTime = mt; cachePath = p;
            return d;
        }
    }
    return cache;   // 文件不在（或读不到）时退回上一次的缓存
}

// 稳健读取：① 共享域 plist（jbroot，真正管用的那条）→ ② 共享 suite（容器内）
//          → ③ cfprefsd 域 → ④ 容器里的同名 plist
static inline id MVGet(NSString *key) {
    NSDictionary *shared = MVSharedPrefs();
    id v = shared[key];
    if (v) return v;
    v = [MVPrefs() objectForKey:key];
    if (v) return v;
    CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                     (__bridge CFStringRef)MV_PREFS_ID);
    if (cv) return CFBridgingRelease(cv);
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:
        [MV_GLOBAL_PREFS stringByAppendingFormat:@"%@.plist", MV_PREFS_ID]];
    return file[key];
}
static inline NSString* MVGetStr(NSString *key) {
    id v = MVGet(key);
    return [v isKindOfClass:[NSString class]] ? v : (v ? [v description] : @"");
}

// 读取来源自检（给「测试配置」用）：告诉你这个值究竟是从哪条通道读到的
static inline NSString* MVReadDiag(void) {
    NSMutableString *s = [NSMutableString string];
    NSDictionary *shared = MVSharedPrefs();
    [s appendFormat:@"① 越狱共享文件 %@: %@\n",
        MV_JBROOT_PREFS, shared[@"apiKey"] ? @"有 ✅" : (shared ? @"文件在但无 apiKey" : @"读不到")];
    [s appendFormat:@"② 容器 suite: %@\n", [MVPrefs() objectForKey:@"apiKey"] ? @"有" : @"无"];
    CFPropertyListRef cv = CFPreferencesCopyAppValue(CFSTR("apiKey"),
                                                     (__bridge CFStringRef)MV_PREFS_ID);
    [s appendFormat:@"③ cfprefsd: %@", cv ? @"有" : @"无（正常，微信里会被容器映射）"];
    if (cv) CFRelease(cv);
    return s;
}

static inline BOOL MVEnabled(void)    { id v = MVGet(@"enabled"); return v ? [v boolValue] : YES; }

// 引擎模式：0 = 离线(AVSpeech 系统中文，机器人音)；1 = 云端克隆音色(CosyVoice，你的声音)
static inline NSInteger MVEngineMode(void){ id v = MVGet(@"engineMode"); return v ? [v integerValue] : 1; }

// DashScope（北京地域）凭证
static inline NSString* MVAPIKey(void)     { return MVGetStr(@"apiKey"); }
static inline NSString* MVWorkspace(void)  { return MVGetStr(@"workspace"); }

// 多音色列表：@[@{name, voiceID, model}]
static inline NSArray* MVVoices(void) {
    id v = MVGet(@"voices");
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static inline NSDictionary* MVCurrentVoice(void) {
    NSString *cur = MVGetStr(@"currentVoiceID");
    if (cur.length) {
        for (NSDictionary *d in MVVoices()) if ([d[@"voiceID"] isEqualToString:cur]) return d;
    }
    return MVVoices().firstObject;
}
static inline NSString* MVCurrentVoiceID(void) { return MVCurrentVoice()[@"voiceID"] ?: @""; }
static inline NSString* MVCurrentModel(void)   { return MVCurrentVoice()[@"model"] ?: @"cosyvoice-v3.5-plus"; }

// 声音设计（文字描述生成音色）固定用 v3.5-plus：只有 cosyvoice v3.x 系列支持该能力。
// 注意：target_model 必须与后续合成用的模型一致，否则合成会失败 —— 所以存音色时要记下这个值。
static inline NSString* MVDesignModel(void) { return @"cosyvoice-v3.5-plus"; }

// OSS（克隆音色时一次性托管参考音频，拿公网 URL 给 DashScope）
static inline NSString* MVOSSBucket(void)   { return MVGetStr(@"ossBucket"); }
static inline NSString* MVOSSHost(void)     { return MVGetStr(@"ossHost"); }   // 形如 oss-cn-hangzhou.aliyuncs.com
static inline NSString* MVOSSAk(void)       { return MVGetStr(@"ossAk"); }
static inline NSString* MVOSSSk(void)       { return MVGetStr(@"ossSk"); }

// 触发方式：0 = 悬浮按钮（默认）；1 = 长按录音键
static inline NSInteger MVTrigger(void){ id v = MVGet(@"trigger"); return v ? [v integerValue] : 0; }
