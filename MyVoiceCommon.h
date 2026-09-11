#import <Foundation/Foundation.h>

// 统一日志前缀，方便在设备 syslog 里过滤调试。
#define MVLog(fmt, ...) NSLog(@"[MyVoice] " fmt, ##__VA_ARGS__)

// 设置域（PreferenceLoader 写入此 bundle id 的 plist）
#define MV_PREFS_ID @"com.yzdmm2024.myvoice"

static inline NSUserDefaults* MVPrefs(void) {
    static NSUserDefaults *d;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:MV_PREFS_ID]; });
    return d;
}
static inline BOOL MVEnabled(void)    { id v = [MVPrefs() objectForKey:@"enabled"]; return v ? [v boolValue] : YES; }
static inline NSString* MVVoiceID(void){ return [MVPrefs() stringForKey:@"voiceID"] ?: @""; }
static inline NSInteger MVTrigger(void){ id v = [MVPrefs() objectForKey:@"trigger"]; return v ? [v integerValue] : 0; }
