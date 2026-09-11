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

// 稳健读取：① 共享 suite → ② cfprefsd 域 → ③ 直接读 plist（微信沙箱下的兜底）。
// 设置面板写的是 ①+②，三种路径任一命中即可，避免"填了不生效"。
static inline id MVGet(NSString *key) {
    id v = [MVPrefs() objectForKey:key];
    if (v) return v;
    CFPropertyListRef cv = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                     (__bridge CFStringRef)MV_PREFS_ID);
    if (cv) return CFBridgingRelease(cv);
    NSString *p = [@"/var/mobile/Library/Preferences/" stringByAppendingFormat:@"%@.plist", MV_PREFS_ID];
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:p];
    return file[key];
}
static inline NSString* MVGetStr(NSString *key) {
    id v = MVGet(key);
    return [v isKindOfClass:[NSString class]] ? v : (v ? [v description] : @"");
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

// OSS（克隆音色时一次性托管参考音频，拿公网 URL 给 DashScope）
static inline NSString* MVOSSBucket(void)   { return MVGetStr(@"ossBucket"); }
static inline NSString* MVOSSHost(void)     { return MVGetStr(@"ossHost"); }   // 形如 oss-cn-hangzhou.aliyuncs.com
static inline NSString* MVOSSAk(void)       { return MVGetStr(@"ossAk"); }
static inline NSString* MVOSSSk(void)       { return MVGetStr(@"ossSk"); }

// 触发方式：0 = 悬浮按钮（默认）；1 = 长按录音键
static inline NSInteger MVTrigger(void){ id v = MVGet(@"trigger"); return v ? [v integerValue] : 0; }
