#import <Foundation/Foundation.h>

// 统一日志前缀，方便在设备 syslog 里过滤调试。
#define MVLog(fmt, ...) NSLog(@"[MyVoice] " fmt, ##__VA_ARGS__)

// 设置域（PreferenceLoader 写入此 bundle id 的 plist）
#define MV_PREFS_ID @"com.yzdmm2024.myvoice"

// 微信语音标准：24kHz / 单声道 / S16。SILK 编码 + 直发都按这个来。
#define MV_WECHAT_SR 24000.0

static inline NSUserDefaults* MVPrefs(void) {
    static NSUserDefaults *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:MV_PREFS_ID]; });
    return d;
}
static inline BOOL MVEnabled(void)    { id v = [MVPrefs() objectForKey:@"enabled"]; return v ? [v boolValue] : YES; }

// 引擎模式：0 = 离线(AVSpeech 系统中文，机器人音)；1 = 云端克隆音色(CosyVoice，你的声音)
static inline NSInteger MVEngineMode(void){ id v = [MVPrefs() objectForKey:@"engineMode"]; return v ? [v integerValue] : 1; }

// DashScope（北京地域）凭证
static inline NSString* MVAPIKey(void)     { return [MVPrefs() stringForKey:@"apiKey"] ?: @""; }
static inline NSString* MVWorkspace(void)  { return [MVPrefs() stringForKey:@"workspace"] ?: @""; }

// 多音色列表：@[@{name, voiceID, model}]
static inline NSArray* MVVoices(void) {
    id v = [MVPrefs() objectForKey:@"voices"];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static inline NSDictionary* MVCurrentVoice(void) {
    NSString *cur = [MVPrefs() stringForKey:@"currentVoiceID"];
    if (cur.length) {
        for (NSDictionary *d in MVVoices()) if ([d[@"voiceID"] isEqualToString:cur]) return d;
    }
    return MVVoices().firstObject;
}
static inline NSString* MVCurrentVoiceID(void) { return MVCurrentVoice()[@"voiceID"] ?: @""; }
static inline NSString* MVCurrentModel(void)   { return MVCurrentVoice()[@"model"] ?: @"cosyvoice-v3.5-plus"; }

// OSS（克隆音色时一次性托管参考音频，拿公网 URL 给 DashScope）
static inline NSString* MVOSSBucket(void)   { return [MVPrefs() stringForKey:@"ossBucket"] ?: @""; }
static inline NSString* MVOSSHost(void)     { return [MVPrefs() stringForKey:@"ossHost"] ?: @""; }   // 形如 oss-cn-hangzhou.aliyuncs.com
static inline NSString* MVOSSAk(void)       { return [MVPrefs() stringForKey:@"ossAk"] ?: @""; }
static inline NSString* MVOSSSk(void)       { return [MVPrefs() stringForKey:@"ossSk"] ?: @""; }

// 触发方式：0 = 悬浮按钮（默认）；1 = 长按录音键
static inline NSInteger MVTrigger(void){ id v = [MVPrefs() objectForKey:@"trigger"]; return v ? [v integerValue] : 0; }
