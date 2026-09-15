#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 统一日志前缀，方便在设备 syslog 里过滤调试。
//
// 2.1.0 起日志同时落盘 —— 录音管线劫持是否生效、微信录音器的真实采样率这些关键事实
// 只能在真机上看到，而让用户抓 syslog 太麻烦。落盘后 Filza 直接打开即可。
//   · 优先写 /var/jb/var/mobile/Library/Preferences/com.yzdmm2024.myvoice.log（rootless jbroot）
//   · 写不进去就退微信自己容器的 Documents/MyVoice.log
// 超过 512KB 自动清空重来，避免无限膨胀。
static inline NSString* MVLogFilePath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *cands = @[
            @"/var/jb/var/mobile/Library/Preferences/com.yzdmm2024.myvoice.log",
            [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/MyVoice.log"],
        ];
        for (NSString *p in cands) {
            [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];
            if ([fm fileExistsAtPath:p]) { path = p; break; }
            if ([fm createFileAtPath:p contents:nil attributes:nil]) { path = p; break; }
        }
    });
    return path;
}

static inline void MVLogAppend(NSString *line) {
    NSString *path = MVLogFilePath();
    if (!path.length || !line.length) return;
    @synchronized(@"mv-log") {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        @try {
            unsigned long long sz = [fh seekToEndOfFile];
            if (sz > 512 * 1024) {                       // 防无限增长
                [fh closeFile];
                [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (!fh) return;
                [fh seekToEndOfFile];
            }
            static NSDateFormatter *df = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                df = [[NSDateFormatter alloc] init];
                df.dateFormat = @"MM-dd HH:mm:ss.SSS";
            });
            NSString *out = [NSString stringWithFormat:@"%@ %@\n",
                             [df stringFromDate:[NSDate date]], line];
            [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) { /* 日志失败绝不能影响主流程 */ }
    }
}

// MVLog：syslog + 落盘。普通代码路径用它。
#define MVLog(fmt, ...) do { \
    NSString *_mvS = [NSString stringWithFormat:@"[MyVoice] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", _mvS); \
    MVLogAppend(_mvS); \
} while (0)

// MVLogS：只 NSLog 不落盘。★ 专供音频实时回调等对延迟敏感、不能做文件 IO 的地方。
#define MVLogS(fmt, ...) do { \
    NSLog(@"[MyVoice] " fmt, ##__VA_ARGS__); \
} while (0)

// 设置域（设置面板 + tweak 共用）
#define MV_PREFS_ID @"com.yzdmm2024.myvoice"
// 跨进程通知名（设置面板改完发，微信里的面板监听）
#define MV_CHANGED_NOTIFY "com.yzdmm2024.myvoice/settings"

// ---- 解锁验证 (LocSim 算法: SHA256(UDID) -> 15 位码) ----
BOOL MVUnlocked(void);
void MVShowLicenseAlert(void);


// 微信录音管线实测采样率：**16kHz / 单声道 / S16**（2.1.0 起改用录音管线劫持后校正）。
// 证据：AudioQueueNewInput 申请格式 + 实测 buffer 8000B/250ms（= 32000 B/s = 16000 Hz × 2B）。
// ⚠️ 2.0.17 之前这里写的是 24000（当时是"自己编码 SILK 再直发"的推测值），
//    改成录音管线劫持后必须以管线真实采样率为准，否则音调/时长会错位。
#define MV_WECHAT_SR 16000.0

// ---- S16 单声道重采样（线性插值，确定性实现）----
// 为什么要抽到公共头：云端 wav 解码与录音管线注入必须用**同一条**实现。
// 之前云端用 AVAudioConverter，而 convertToBuffer:error:withInputFromBlock: 的
// 输入 block 每次都被返回同一个 inBuf（HaveData），转换器在一次调用里需要多于一个
// 输入块时会**重复消费同一段输入** → 输出里插进重复帧，听感就是"一卡一卡/两个声音"。
static inline NSData* MVResampleS16Mono(NSData *src, double srcRate, double dstRate) {
    if (!src.length || srcRate <= 0 || dstRate <= 0) return src ?: [NSData data];
    NSUInteger nSrc = src.length / 2;
    if (!nSrc) return nil;
    double diff = srcRate > dstRate ? srcRate - dstRate : dstRate - srcRate;
    if (diff < 1.0) return src;                       // 同采样率：原样（零拷贝）
    double ratio = dstRate / srcRate;
    NSUInteger nDst = (NSUInteger)((double)nSrc * ratio + 0.5);
    if (!nDst) return nil;
    const short *in = (const short*)src.bytes;
    NSMutableData *out = [NSMutableData dataWithLength:nDst * 2];
    if (!out) return nil;
    short *od = (short*)out.mutableBytes;
    for (NSUInteger i = 0; i < nDst; i++) {
        double pos = (double)i / ratio;
        NSUInteger idx = (NSUInteger)pos;
        double frac = pos - (double)idx;
        if (idx >= nSrc) idx = nSrc - 1;
        double a = in[idx];
        double b = (idx + 1 < nSrc) ? in[idx + 1] : in[idx];
        double v = a + (b - a) * frac;
        if (v > 32767.0) v = 32767.0; else if (v < -32768.0) v = -32768.0;
        od[i] = (short)v;
    }
    return out;
}

// 把 16kHz 单声道 S16 PCM 包成标准 WAV（诊断落盘用：可以直接拖出来听）
static inline NSData* MVWav16kFromPCM(NSData *pcm) {
    if (!pcm.length || pcm.length > 0xFFFFFF00u) return nil;
    uint32_t dl = (uint32_t)pcm.length;
    unsigned char h[44];
    uint32_t rl = 36 + dl, fl = 16, sr = 16000, br = 32000;
    uint16_t af = 1, nc = 1, ba = 2, bps = 16;
    memcpy(h,      "RIFF", 4); memcpy(h + 4,  &rl, 4);
    memcpy(h + 8,  "WAVE", 4); memcpy(h + 12, "fmt ", 4);
    memcpy(h + 16, &fl, 4);    memcpy(h + 20, &af, 2);
    memcpy(h + 22, &nc, 2);    memcpy(h + 24, &sr, 4);
    memcpy(h + 28, &br, 4);    memcpy(h + 32, &ba, 2);
    memcpy(h + 34, &bps, 2);   memcpy(h + 36, "data", 4);
    memcpy(h + 40, &dl, 4);
    NSMutableData *d = [NSMutableData dataWithBytes:h length:44];
    [d appendData:pcm];
    return d;
}

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

// 稳健读取：★ 2.4.3 起【容器 suite 优先】→ ② 共享域 plist（jbroot）→ ③ cfprefsd 域 → ④ 全局文件。
//   为什么调换顺序：面板里的选择（qwenVoice/currentVoiceID/ttsProvider…）通过 MVSetShared
//   写容器 + jbroot 两处，但微信沙箱对 jbroot 的写入可能失败/滞后 —— 旧序 jbroot 优先时，
//   读到的永远是 Settings 写下的旧值，导致「选了音色却不出现在面板/不生效」。
//   容器里存的一定是微信进程自己写的最新值；而 Settings 写入的键（apiKey/oss*）在微信
//   容器里不存在，自然落到 jbroot 那一级 —— 两边互不干扰。
static inline id MVGet(NSString *key) {
    id v = [MVPrefs() objectForKey:key];
    if (v) return v;
    NSDictionary *shared = MVSharedPrefs();
    v = shared[key];
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

// 写入共享域：容器 suite + jbroot plist 两处都写（微信侧读哪条都能拿到）
static inline void MVSetShared(NSString *key, id value) {
    if (!key.length) return;
    [MVPrefs() setObject:value forKey:key];
    [MVPrefs() synchronize];
    NSString *p = [MV_JBROOT_PREFS stringByAppendingFormat:@"%@.plist", MV_PREFS_ID];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p];
    if (!d) d = [NSMutableDictionary dictionary];
    d[key] = value;
    [d writeToFile:p atomically:YES];   // 沙箱可能拒绝写 jbroot，失败无所谓（上面已写容器）
}

// ★ 2.8.13：克隆音色列表专用写入 —— 在 MVSetShared（容器 + jbroot）基础上，
//   额外写一份到 CFPreferences 全局域（kCFPreferencesAnyUser），保证微信/QQ 互通。
//   读端见 MVVoices()：全局域优先，退化到 jbroot / 容器都不影响。
static inline void MVSetSharedVoiceList(NSArray *vs) {
    if (!vs) vs = @[];
    MVSetShared(@"voices", vs);
    CFPreferencesSetValue((__bridge CFStringRef)@"voices",
                          (__bridge CFPropertyListRef)vs,
                          (__bridge CFStringRef)MV_PREFS_ID,
                          kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    CFPreferencesSynchronize((__bridge CFStringRef)MV_PREFS_ID,
                             kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
}

// 上次捕获到的会话（微信 8.0.75 上 VC 里没有 talker 字段，只能靠 hook 抓 + 记住）
// 存「值 + 时间戳」，超过 30 分钟视为过期，避免把消息发给很久以前打开过的会话。
static inline void MVSetLastTalker(NSString *talker) {
    if (!talker.length) return;
    MVSetShared(@"lastTalker", talker);
    MVSetShared(@"lastTalkerAt", @([[NSDate date] timeIntervalSince1970]));
}
static inline NSString* MVLastTalker(void) {
    NSString *t = MVGetStr(@"lastTalker");
    if (!t.length) return nil;
    id at = MVGet(@"lastTalkerAt");
    if (at) {
        NSTimeInterval ts = [at doubleValue];
        if (ts > 0 && [[NSDate date] timeIntervalSince1970] - ts > 1800) return nil;
    }
    return t;
}

static inline BOOL MVEnabled(void)    { id v = MVGet(@"enabled"); return v ? [v boolValue] : YES; }

// 引擎模式：0 = 离线(AVSpeech 系统中文，机器人音)；1 = 云端(CosyVoice 克隆 或 千问 Qwen-TTS)
static inline NSInteger MVEngineMode(void){ id v = MVGet(@"engineMode"); return v ? [v integerValue] : 1; }

// ===== ★ 2.8.35：发音通道 ttsChannel（三选一，天然互斥） =====
//   0 = 自建服务器        本机/ECS 上的 CosyVoice，完全免费，不碰 DashScope
//   1 = 云端 CosyVoice    阿里云百炼，耗额度（克隆 / 设计音色）
//   2 = 云端千问 Qwen-TTS 阿里云百炼，耗额度（官方预置音色，无需克隆）
//
// 为什么把两个开关并成一个通道：
//   2.8.34 及以前是「selfHostEnabled 开关」+「ttsProvider 二选一」两组**独立**设置，
//   两者可以同时成立 —— 用户明明开了自建服务器，千问预置音色那条路仍然照走阿里云，
//   于是"开了免费模式还在扣额度"，而且从界面上根本看不出来钱花在哪。
//   现在 selfHostEnabled / ttsProvider 全部由 ttsChannel **单向派生**，
//   数据结构上就不可能出现"既要自建服务器、又要千问"的状态。
//
// 自建系的键必须走【jbroot 共享域优先】：面板跑在微信进程里，容器值会遮住设置页写入的值。
static inline id MVChannelGet(NSString *key) {
    NSDictionary *sh = MVSharedPrefs();
    if ([sh isKindOfClass:[NSDictionary class]]) {
        id v = sh[key];
        if (v) return v;
    }
    return MVGet(key);
}
static inline NSInteger MVChannel(void) {
    id v = MVChannelGet(@"ttsChannel");
    if (v) { NSInteger n = [v integerValue]; if (n >= 0 && n <= 2) return n; }
    // 旧版兼容：没写过 ttsChannel 的老用户，按老的两个键推导一次（结果与旧行为一致）
    id sh = MVChannelGet(@"selfHostEnabled");
    if (sh && [sh boolValue]) return 0;
    id tp = MVChannelGet(@"ttsProvider");
    if (tp && [tp integerValue] == 0) return 1;
    return 2;
}
// 云端 TTS 服务商：0 = CosyVoice 族（含自建服务器）；1 = 千问 Qwen-TTS
// ★ 只有 ttsChannel==2 才是千问 —— 自建服务器通道下**永远**返回 0，千问不可能被接走。
static inline NSInteger MVTTSProvider(void){ return (MVChannel() == 2) ? 1 : 0; }

// 通道名（界面文案）
static inline NSString* MVChannelName(void) {
    switch (MVChannel()) {
        case 0:  return @"自建服务器（免费·不耗额度）";
        case 1:  return @"云端 CosyVoice（耗额度）";
        default: return @"云端千问 TTS（耗额度）";
    }
}
static inline NSString* MVChannelShortName(void) {
    switch (MVChannel()) {
        case 0:  return @"自建";
        case 1:  return @"CV";
        default: return @"千问";
    }
}
static inline BOOL MVChannelIsPaid(void) { return MVChannel() != 0; }

// ===== ★ 2.8.35：地址脱密 =====
// 服务器地址（公网 IP + 端口）属隐私信息，直接印在说明文字/日志里等于公开暴露，
// 凡是"显示给用户看 / 落日志"的地方一律先过这里：例 a.b.c.d → a.b.*.*
// 本机回环与内网（127.0.0.1 / localhost / 192.168.*）不遮，方便本地调试。
static inline NSString* MVMaskHost(NSString *urlOrHost) {
    NSString *s = urlOrHost ?: @"";
    if (!s.length) return @"(未填写)";
    NSRange sch = [s rangeOfString:@"://"];
    NSString *head = @"", *rest = s;
    if (sch.location != NSNotFound) {
        head = [s substringToIndex:sch.location + 3];
        rest = [s substringFromIndex:sch.location + 3];
    }
    NSRange slash = [rest rangeOfString:@"/"];
    NSString *hostport = (slash.location == NSNotFound) ? rest : [rest substringToIndex:slash.location];
    NSString *tail = (slash.location == NSNotFound) ? @"" : [rest substringFromIndex:slash.location];
    if ([hostport hasPrefix:@"127.0.0.1"] || [hostport hasPrefix:@"localhost"] ||
        [hostport hasPrefix:@"192.168."] || [hostport hasPrefix:@"10."]) return s;
    NSArray *parts = [hostport componentsSeparatedByString:@":"];
    NSString *host = parts.count ? parts[0] : hostport;
    NSArray *oct = [host componentsSeparatedByString:@"."];
    NSString *masked = host;
    if (oct.count == 4 && [oct[3] length]) {
        masked = [NSString stringWithFormat:@"%@.%@.*.*", oct[0], oct[1]];
    } else if (host.length > 4) {
        masked = [NSString stringWithFormat:@"%@****%@",
                  [host substringToIndex:1],
                  [host substringFromIndex:host.length - 3]];
    }
    NSMutableString *out = [NSMutableString stringWithString:head];
    [out appendString:masked];
    if (parts.count > 1 && [parts[1] length]) [out appendFormat:@":%@", parts[1]];
    [out appendString:tail];
    return out;
}

// 千问 Qwen-TTS 模型名（qwen3-tts-flash 支持全部 48 个预置音色；老 qwen-tts 只支持前 4 个）
static inline NSString* MVQwenModel(void) {
    NSString *v = MVGetStr(@"qwenModel");
    return v.length ? v : @"qwen3-tts-flash";
}
// 千问当前预置音色（voice 参数，如 Cherry；面板里点选后会写到这个键）
static inline NSString* MVQwenVoice(void) {
    NSString *v = MVGetStr(@"qwenVoice");
    return v.length ? v : @"Cherry";
}

// 千问 Qwen-TTS 语气（emotion）：默认/生气/愤怒/快乐/开朗
static inline NSString* MVQwenEmotion(void) {
    NSString *v = MVGetStr(@"qwenEmotion");
    return v.length ? v : @"default";
}
// 千问 Qwen-TTS 语速：0.5 ~ 2.0，默认 1.0
static inline double MVQwenSpeed(void) {
    id v = MVGet(@"qwenSpeed");
    if (v) {
        double d = [v doubleValue];
        if (d >= 0.5 && d <= 2.0) return d;
    }
    return 1.0;
}

// ===== ★ 2.8.5：CosyVoice 克隆音色的「表现参数」 =====
// 官方 SpeechSynthesizer 支持 rate / pitch / volume / instruction / language_hints，
// 但 2.8.4 及以前一个都没传 → 克隆音色只能用模型默认的朗读腔（字正腔圆、每字等长）
// = 用户说的"浓烈 AI 味"。这里全部补齐，并把「一键风格」落到 instruction 上。
//
// 一键风格 id：0=默认 1=人情味 2=标准腔 3=慢语速 4=亲切 5=活泼
static inline NSInteger MVCosyStyle(void) {
    id v = MVGet(@"cosyStyle");
    return v ? [v integerValue] : 0;
}
// ★ 2.8.7：风格表改成 8 档并与千问共用（0..7），并抽出 MVStyleInstruction(idx) ——
//   千问那条分支要写的是自己的 qwenStyle，所以不能再用"读 cosyStyle"的旧封装。
static inline NSArray* MVStyleNames(void) {
    return @[@"默认", @"人情味", @"标准腔", @"慢语速", @"亲切", @"活泼", @"生气", @"快乐"];
}
static inline NSArray* MVCosyStyleNames(void) { return MVStyleNames(); }
// 每种风格推荐的语速档位（0 = 不干预）。「一键」就该一步到位。
static inline double MVStyleRate(NSInteger idx) {
    switch (idx) {
        case 1: return 0.95;   // 人情味：略慢一点更自然
        case 2: return 1.00;   // 标准腔
        case 3: return 0.80;   // 慢语速
        case 4: return 0.95;   // 亲切
        case 5: return 1.05;   // 活泼
        case 6: return 1.00;   // 生气
        case 7: return 1.05;   // 快乐
        default: return 0.0;
    }
}
static inline double MVCosyStyleRate(NSInteger idx) { return MVStyleRate(idx); }
// ★ 2.8.7：指令长度按「汉字算 2」裁剪（CosyVoice / Qwen-Audio-TTS 官方规则）。
//   必须定义在 MVCosyInstruction / MVQwenInstructions 之前 —— C 不允许"先用后定义"。
static inline NSString* MVInstructionTrim(NSString *s, NSInteger limit) {
    if (!s.length) return s;
    NSInteger w = 0;
    NSUInteger i = 0;
    for (; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        NSInteger step = (c >= 0x2E80) ? 2 : 1;    // 汉字/假名/谚文等宽字符
        if (w + step > limit) break;
        w += step;
    }
    return (i >= s.length) ? s : [s substringToIndex:i];
}

// ===== ★ 2.8.8：方言强化 —— 不止一句「请用X话说」 =====
// 旧版指令："请用湖南话说这句话。"
//   → 模型经常输出"普通话带一两个方言词"，方言不明显。
// 2.8.8 新增：每种方言后面追加方言特征描述（"尾音上挑""前后鼻音不分"等），
//   模型有了"听感参考"，出方言的概率和地道程度都明显提升。
// 写代码的代价是表维护，运行时 0 开销；指令长度仍在 100 字符（汉字算 2）以内。
// ★ 必须定义在 MVCosyInstruction 之前（C 要求 inline 函数先定义后使用）。
static inline NSDictionary* MVDialectTips(void) {
    static NSDictionary *m;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        m = @{
            @"普通话":   @"",
            @"广东话":   @"广东话（粤语）说，发音带粤语腔调，比如「的」读「嘅」、「什么」读「乜嘢」，句末少用「吗」。",
            @"重庆话":   @"重庆话说，发音短促有力，翘舌音重，「的/得/地」常混读，鼻音重，前后鼻音不分。",
            @"东北话":   @"东北话说，儿化音明显，「什么」读「啥」，「怎么」读「咋」，尾音上扬像唠嗑。",
            @"甘肃话":   @"甘肃话说，西北腔调，咬字硬一些，前后鼻音区分不明显，「的」读「滴」。",
            @"贵州话":   @"贵州话说，川黔口音，语调起伏大，「的」读成「嘞」，句子短促带节奏。",
            @"浙江话":   @"浙江话说，吴语腔调，软糯感，「我」读成类似「吴」，前后鼻音不分，句尾常带「咯」。",
            @"河北话":   @"河北话说，华北腔，咬字干脆，「什么」常读「啥」，儿化音点缀。",
            @"河南话":   @"河南话说，中原腔调，「的」读「嘞」「什么」读「啥」，语调平直朴实。",
            @"湖北话":   @"湖北话说，西南方言底子，「的」读成「滴」，前后鼻音不分，尾音常带「撒」。",
            @"湖南话":   @"湖南话说，长沙一带口音，尾音常上挑，「我」读成「哦」，「的」读成「滴」，整体带点塑料普通话味儿。",
            @"江西话":   @"江西话说，赣方言区，「的」读成「个」或「咯」，前后鼻音不分，语调起伏小。",
            @"闽南话":   @"闽南话说，闽南腔调，「的」读成「e」，「什么」读成「啥米」，语调婉转。",
            @"宁波话":   @"宁波话说，吴语宁波腔，软糯绵长，「我」读成「阿拉」，前后鼻音混淆。",
            @"宁夏话":   @"宁夏话说，西北腔调，「的」读「滴」，「什么」读「啥」，语调平缓朴实。",
            @"青岛话":   @"青岛话说，胶辽口音，一/三声常错位，「什么」读「啥」，下声调有拖音。",
            @"陕西话":   @"陕西话说，关中腔调，咬字重且平，「的」读成「嘞」，句尾常带「哩」。",
            @"山西话":   @"山西话说，并州腔，前后鼻音不分，「我」读成「额」，语调起伏大。",
            @"山东话":   @"山东话说，胶辽/鲁西口音，「的」读「嘞」，语调上扬有气势。",
            @"上海话":   @"上海话说，吴语上海腔，「我」读成类似「吾」，前后鼻音不分，语调轻快。",
            @"四川话":   @"四川话说，西南官话，「的」读成「嘞」，「什么」读「啥」，语调起伏带拖音。",
            @"天津话":   @"天津话说，天津腔调，儿化音重，「什么」读「嘛」，语调起伏大。",
            @"云南话":   @"云南话说，西南官话底子，「的」读成「嘞」，语调起伏大。",
            @"阳江话":   @"阳江白话（粤语阳江片）说，带阳江口音，语调平缓自然，「我」带阳江腔，用词偏粤语习惯，句尾常带「咯」。",
            @"皖北话":   @"皖北中原官话（阜阳一带）说，口音淳厚朴实，咬字清楚，「的」常读「嘞」，前后鼻音不分，语调平稳像拉家常。",
        };
    });
    return m;
}
// 方言 → instruction（拼接"请用X说"+方言特征描述）。
// ★ 2.8.8：旧版只一句"请用X说"，模型常常当作"提醒词"忽略；2.8.8 把方言的发声特征
//   也写进去，模型有了具体"听感参考"，效果明显更稳。
// ★ 2.8.14：阳江话/皖北话 引擎未训练，纯文本指令会被忽略退回普通话。
//   映射成最接近的已支持方言（阳江话→广东话/粤语，同属粤语片；皖北话→河南话/中原官话），
//   让指令真正生效、出真腔（非精确当地话，但明显不是普通话）。
static inline NSString* MVDialectInstruction(NSString *dialect) {
    if (!dialect.length || [dialect isEqualToString:@"普通话"]) return nil;
    NSString *engineDialect = dialect;
    if ([dialect isEqualToString:@"阳江话"]) engineDialect = @"广东话";
    else if ([dialect isEqualToString:@"皖北话"]) engineDialect = @"河南话";
    NSString *tip = MVDialectTips()[engineDialect];
    if (tip.length) return [NSString stringWithFormat:@"请用%@说这句话。%@", engineDialect, tip];
    return [NSString stringWithFormat:@"请用%@说这句话。", engineDialect];
}

// 风格 → 语气句（按索引，不读 prefs，便于千问/克隆共用）
// ★ 2.8.8：每档风格追加「听起来应该像什么」的具体听感描述，
//   让模型有明确的情感/发声参考，不止一句模糊的"语气活泼"。
static inline NSString* MVStyleInstruction(NSInteger idx) {
    switch (idx) {
        case 1: return @"用自然随意的日常聊天语气说，像跟朋友发语音一样，语速自然，不要播音腔。听起来就是身边的人在跟你闲谈，没有朗读感。";
        case 2: return @"用标准播报腔，字正腔圆，语气平稳，吐字清晰。像新闻主播一样，每个字饱满有力，句子之间有明显停顿，整体很正式。";
        case 3: return @"语速放慢，吐字清晰，句子之间自然停顿。听起来不急，每个字都能听清楚，适合讲重点或说给老人听。";
        case 4: return @"语气温和亲切，像长辈在关心人，语速舒缓。声音带暖意，不急不躁，让人愿意听下去。";
        case 5: return @"语气活泼俏皮，带一点笑意，节奏轻快。声音上扬发亮，像在跟你开玩笑或分享开心事，整体情绪饱满。";
        case 6: return @"语气带着一点生气和不耐烦。声音收紧，语速偏快，尾音略硬，听起来明显有点小情绪。";
        case 7: return @"语气快乐开朗，情绪饱满。声音发亮有笑意，节奏轻快上扬，整体很阳光。";
        default: return nil;
    }
}
static inline NSString* MVCosyStyleInstruction(void) {
    return MVStyleInstruction(MVCosyStyle());
}

// ★ 2.8.8：指令强化开关 —— 在方言/风格指令前面加一句"务必严格按照以下指令执行"。
//   模型对前置"强化词"普遍更敏感（实验反复证实），尤其在指令较长时差异明显。
//   默认开 —— 反正没增加字符成本，"调了没反应"的最大改善就是这一条。
// ★ 必须定义在 MVCosyInstruction / MVQwenInstructions 之前（C 要求 inline 函数先定义后使用）。
static inline BOOL MVReinforceInstruction(void) {
    id v = MVGet(@"reinforceInstruction");
    return v ? [v boolValue] : YES;
}
// ★ 2.8.8 强化前缀 —— 不要影响风格判断，但能明显提升遵循度
static inline NSString* MVReinforcePrefix(void) {
    return MVReinforceInstruction() ? @"务必严格按照以下指令执行。" : @"";
}
// ★ 2.8.6：instruction 改成「方言句 + 语气句」两段拼接。
//   官方只有一个 instruction 字段，但方言和语气是两个维度，不该互相顶掉：
//   旧实现里点一次「风格」就会清掉 cosyInstruction —— 而方言写的正是这个字段，
//   于是面板还显示着"方言：湖南话"，实际指令已经空了（静默失效，最难查的一类坑）。
//   规则：方言（独立维度，不被风格清掉）+（自定义指令优先于一键风格）；总长按官方上限截到 100 字符。
//   注：这里内联生成方言句，避免依赖定义在后面的 MVDialectInstruction（C 需先声明后用）。
// ★ 2.8.8：拼接顺序 强化前缀 + 方言 + 风格/自定义，让"强化"贯穿全指令。
static inline NSString* MVCosyInstruction(void) {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *prefix = MVReinforcePrefix();
    if (prefix.length) [parts addObject:prefix];
    NSString *dname = MVGetStr(@"cosyDialect");
    if (dname.length && ![dname isEqualToString:@"普通话"]) {
        // 直接调定义在本头文件前面的 MVDialectInstruction —— 已强化为「方言+特征描述」
        NSString *di = MVDialectInstruction(dname);
        if (di.length) [parts addObject:di];
    }
    NSString *custom = MVGetStr(@"cosyInstruction");
    if (custom.length) {
        [parts addObject:custom];
    } else {
        NSString *st = MVCosyStyleInstruction();
        if (st.length) [parts addObject:st];
    }
    if (!parts.count) return nil;
    NSString *out = [parts componentsJoinedByString:@""];
    // ★ 2.8.7：官方是"100 字符，汉字（含日韩汉字）按 2 个字符计算" ——
    //   旧版按 NSString.length 截，一段 60 汉字的语气句实际算 120 → 直接 400。
    return MVInstructionTrim(out, 100);
}
// 语速 0.5~2.0：没单独设过就回落到千问语速，老用户行为不变
static inline double MVCosyRate(void) {
    id v = MVGet(@"cosyRate");
    if (v) { double d = [v doubleValue]; if (d >= 0.5 && d <= 2.0) return d; }
    return MVQwenSpeed();
}
// 音高 0.5~2.0，默认 1.0（只做微调；调太大会有"变声器"感，反而更假）
static inline double MVCosyPitch(void) {
    id v = MVGet(@"cosyPitch");
    if (v) { double d = [v doubleValue]; if (d >= 0.5 && d <= 2.0) return d; }
    return 1.0;
}
// 音量 0~100，默认 50（= 官方标准音量）
static inline NSInteger MVCosyVolume(void) {
    id v = MVGet(@"cosyVolume");
    if (v) { NSInteger n = [v integerValue]; if (n >= 0 && n <= 100) return n; }
    return 50;
}
// ★ 2.8.8：指令强化开关 —— 在方言/风格指令前面加一句"务必严格按照以下指令执行"。
//   模型对前置"强化词"普遍更敏感（实验反复证实），尤其在指令较长时差异明显。
//   默认开 —— 反正没增加字符成本，"调了没反应"的最大改善就是这一条。
//   实际定义已前移到 MVStyleInstruction 后（必须先定义才能被 MVCosyInstruction 调用）。
// instruction 只有 v3.5-flash / v3.5-plus / v3-flash 支持；其它模型传了会 400
static inline BOOL MVCosySupportsInstruction(NSString *model) {
    if (!model.length) return NO;
    if ([model hasPrefix:@"cosyvoice-v3.5-"]) return YES;
    if ([model isEqualToString:@"cosyvoice-v3-flash"]) return YES;
    // ★ 2.8.6：Qwen-Audio-TTS 的声音复刻音色支持任意指令（含方言）—— 别把它挡在外面，
    //   它是唯二支持「湖南话」的复刻模型（CosyVoice 全系没有湖南话）。
    if ([model hasPrefix:@"qwen-audio-3.0-tts"]) return YES;
    return NO;
}

// ===== ★ 2.8.6：复刻目标模型 + 方言（解锁「克隆音色说方言」）=====
// 先说结论（很容易搞错）：声音复刻只学「声线」，不学口音。
//   想让克隆音色说方言，必须靠【合成时的 instruction】指定 —— 参考音频是什么口音没用。
//   而 voice_id 与复刻时的 target_model 强绑定，所以「复刻时选哪个模型」决定了后面能说什么方言：
//     · cosyvoice-v3.5-plus / v3.5-flash / v3-flash 的复刻音色 → 支持任意指令，方言 17 种
//     · qwen-audio-3.0-tts-plus / -flash         的复刻音色 → 方言 21 种，
//       ★ 含「湖南话」「重庆话」等 CosyVoice 完全没有的方言
//   （官方非实时 HTTP 的 model 取值范围里，这两族是并列的；voice-enrollment 的
//     target_model 同样接受 qwen-audio-3.0-tts-*，language_hints / max_prompt_audio_length /
//     enable_preprocess 也只对这几款生效。）
static inline NSArray* MVCosyModelList(void) {
    return @[@"cosyvoice-v3.5-plus", @"cosyvoice-v3-flash",
             @"qwen-audio-3.0-tts-flash", @"qwen-audio-3.0-tts-plus"];
}
static inline NSArray* MVCosyModelLabels(void) {
    return @[@"v3.5+ 音质", @"v3 方言少", @"Qwen 方言全", @"Qwen+ 高质"];
}
static inline NSInteger MVCosyModelIndex(NSString *m) {
    if (!m.length) return 0;
    NSUInteger i = [MVCosyModelList() indexOfObject:m];
    return (i == NSNotFound) ? 0 : (NSInteger)i;
}
// 这个模型能不能吃「方言」指令
static inline BOOL MVCosyModelSupportsDialect(NSString *m) {
    if (!m.length) return NO;
    if ([m hasPrefix:@"qwen-audio-3.0-tts"]) return YES;
    if ([m isEqualToString:@"cosyvoice-v3-flash"]) return YES;
    if ([m hasPrefix:@"cosyvoice-v3.5-"]) return YES;
    return NO;
}
// 各模型可用方言（点一下就写一句 instruction）
static inline NSArray* MVDialectListForModel(NSString *m) {
    static NSArray *cosy = nil, *qwen = nil;
    if (!cosy) cosy = @[@"普通话", @"广东话", @"东北话", @"甘肃话", @"贵州话", @"河南话",
                        @"湖北话", @"江西话", @"闽南话", @"宁夏话", @"山西话", @"陕西话",
                        @"山东话", @"上海话", @"四川话", @"天津话", @"云南话", @"阳江话", @"皖北话"];
    if (!qwen) qwen = @[@"普通话", @"广东话", @"重庆话", @"东北话", @"甘肃话", @"贵州话",
                        @"浙江话", @"河北话", @"河南话", @"湖北话", @"湖南话", @"江西话",
                        @"宁波话", @"宁夏话", @"青岛话", @"陕西话", @"山西话", @"山东话",
                        @"上海话", @"四川话", @"云南话", @"阳江话", @"皖北话"];
    if ([m hasPrefix:@"qwen-audio-3.0-tts"]) return qwen;
    if (MVCosyModelSupportsDialect(m)) return cosy;
    return @[];
}

// ===== ★ 2.8.6：复刻质量参数（官方 voice-enrollment 支持，旧版一个没传）=====
// 只有 qwen-audio-3.0-tts-* / cosyvoice-v3.5-* / v3-flash 这几款支持，
// 传给 v3-plus / v2 会 400，所以按模型判断后再带。
static inline BOOL MVCloneSupportsQuality(NSString *m) {
    if (!m.length) return NO;
    if ([m hasPrefix:@"qwen-audio-3.0-tts"]) return YES;
    if ([m hasPrefix:@"cosyvoice-v3.5-"]) return YES;
    if ([m isEqualToString:@"cosyvoice-v3-flash"]) return YES;
    return NO;
}
// 用多少秒音频做声纹：官方 [3.0, 30.0]，默认 10.0。
// 本插件默认提到 20 秒 —— 连续语音越长，声纹越稳（前提是同一个人、无明显停顿）。
static inline double MVCloneMaxLen(void) {
    id v = MVGet(@"cloneMaxLen");
    if (v) { double d = [v doubleValue]; if (d >= 3.0 && d <= 30.0) return d; }
    return 20.0;
}
// 音频预处理（降噪 / 增强 / 音量规整）：官方默认关。
// 安静干声建议关（最大化还原音色）；有底噪的素材打开更干净。
static inline BOOL MVClonePreprocess(void) {
    id v = MVGet(@"clonePreprocess");
    return v ? [v boolValue] : NO;
}

// ===== ★ 2.8.5：文本「一键纠偏」（纯本地规则，零网络） =====
// TTS 对「阿拉伯数字 / 英文符号 / 无标点长句」念得很怪，书面写法也加重 AI 味。
// 这里做确定性修正：不改变原意，只改"该怎么念"。
// ===== ★ 2.8.8 文本「一键纠偏」：疑问/反问/质疑也能正确加标点 =====
// TTS 对「阿拉伯数字 / 英文符号 / 无标点长句」念得很怪，书面写法也加重 AI 味。
// 这里做确定性修正：不改变原意，只改"该怎么念"。
static inline BOOL MVIsPunctChar(unichar c) {
    switch (c) {
        case 0x3002: case 0xFF0C: case 0xFF01: case 0xFF1F: case 0xFF1B:
        case 0xFF1A: case 0x3001: case 0x2026: case 0x2014: case 0xFF5E:
        case '.': case ',': case '!': case '?': case ';': case ':': case '~':
            return YES;
        default: return NO;
    }
}
// ★ 2.8.8：判断一个句子的语气，用于自动选 "?" / "!" / "。"。
//   旧版只补"。"，用户报"疑问反问质疑后面没有 ? !" —— 这里按关键词扫一遍。
//   优先级：反问/质疑 > 感叹/夸张 > 疑问 > 默认陈述。
static inline unichar MVGuessSentenceEnding(NSString *sent) {
    if (!sent.length) return 0x3002;     // 。

    // 1) 反问 / 质疑 / 夸张感叹（语气最强，给 "!"）
    //    "怎么可能 / 怎么会 / 怎么行 / 怎么这样 / 凭什么 / 居然 / 竟然 / 还 / 明明 / 说好的..."
    //    加「不是吧 / 是吧 / 这像话吗 / 至于吗」这类反问短句
    NSArray *exclaimKeys = @[@"怎么可能", @"怎么会", @"怎么行", @"怎么可以", @"怎么这样",
                             @"怎么就", @"凭什么", @"居然", @"竟然", @"明明", @"说好的",
                             @"说好的呢", @"说走就走", @"居然敢", @"竟然敢", @"还敢",
                             @"太不像话", @"太过分", @"太离谱", @"真是", @"真气",
                             @"什么破", @"怎么能", @"谁信", @"你敢", @"我敢", @"敢问",
                             @"你以为", @"你就能", @"怎么不", @"怎么不去", @"还让不让人",
                             @"还要不要", @"还讲不讲", @"还想怎样", @"行不行啊", @"行不行呀",
                             @"好不好啊", @"好不好呀", @"是不是啊", @"是真是假",
                             @"到底", @"究竟", @"敢不敢", @"能不能啊", @"会不会啊",
                             @"不是吧", @"是吧", @"这像话吗", @"至于吗", @"不至于",
                             @"成何体统", @"好家伙", @"我的天", @"天哪", @"我晕",
                             @"服了", @"服气", @"腻了", @"够了啊", @"够了吧",
                             @"真棒", @"完美", @"太爽了", @"太对了", @"没毛病", @"没得说",
                             @"去不去", @"行不行", @"是不是", @"要不要", @"好不好",
                             @"对不对", @"能不能啊", @"可以啊", @"可以么"];
    for (NSString *k in exclaimKeys)
        if ([sent rangeOfString:k].location != NSNotFound) return 0xFF01;

    // 1.5) 夸张形容词 —— ★ 必须 strong_adj 后面紧跟「了/啊/呀/啦/哦/呢/嘛/呗/!/?」之一，
    //     否则像"今天天气真好"这种陈述句会被误判成感叹。
    //     "太棒了" "好厉害啊" "真好呢" → "!"
    //     "今天天气真好" → "真好"后无标点 → 陈述。
    NSArray *strongAdj = @[@"太棒", @"太好", @"好厉害", @"真厉害", @"真不错", @"真行",
                           @"真牛", @"真香", @"真好", @"真对", @"真快", @"真准",
                           @"真棒", @"多棒", @"多强", @"多牛", @"多厉害", @"多快",
                           @"漂亮", @"给力", @"稳", @"稳啊", @"厉害啊", @"牛啊",
                           @"开心", @"高兴", @"爽", @"舒服", @"贴心", @"到位"];
    NSString *toneSuf = @"了啊啊呀啦哦呢嘛呗!?！？";
    for (NSString *k in strongAdj) {
        NSRange r = [sent rangeOfString:k];
        if (r.location == NSNotFound) continue;
        NSUInteger end = r.location + r.length;
        if (end >= sent.length) continue;                        // 句末刚好在 strongAdj 上（无后缀），不是感叹
        unichar nxt = [sent characterAtIndex:end];
        NSString *nxtS = [NSString stringWithCharacters:&nxt length:1];
        if ([toneSuf rangeOfString:nxtS].location != NSNotFound)
            return 0xFF01;
    }

    // 2) 疑问（问号）—— 出现疑问词
    //    "吗 / 呢 / 吧（句末）/ 怎么 / 什么 / 谁 / 哪 / 为什么 / 难道 / 真的 / 真的吗 /
    //     是不是 / 如何 / 几时 / 何时 / 啥 / 多少 / 几 / 多 / 多久 / 怎么 / 啥时候 /
    //     能不能 / 可不可以 / 行不行 / 好不好 / 对不对"
    if ([sent rangeOfString:@"吗"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"呢"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"怎么"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"什么"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"谁"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"哪"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"为什么"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"为啥"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"难道"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"居然"].location != NSNotFound) return 0xFF1F;   // 也算问
    if ([sent rangeOfString:@"怎么"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"如何"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"几时"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"何时"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多久"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多久了"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多远"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多高"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多大"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多好"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多深"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多少钱"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"多少"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"几个"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"几位"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"几次"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"啥时候"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"哪里"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"是不是"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"能不能"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"可不可以"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"行不行"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"好不好"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"对不对"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"是不是"].location != NSNotFound) return 0xFF1F;
    if ([sent rangeOfString:@"要不"].location != NSNotFound) return 0xFF1F;   // 反问"要不你来"

    return 0x3002;     // 默认陈述句：。
}
// 阿拉伯数字串 → 中文读法
//   1 位     → 零..九
//   2 位     → 十 / 十几 / 几十几
//   3 位整百 → 几百
//   其余     → 逐位（年份 2026→二零二六、报警号 110→一一零、编号 1001→一零零一）
static inline NSString* MVNumberToChinese(NSString *digits) {
    NSArray *d = @[@"零",@"一",@"二",@"三",@"四",@"五",@"六",@"七",@"八",@"九"];
    NSUInteger len = digits.length;
    if (!len) return digits;
    if (len == 1) return d[(NSUInteger)[digits intValue]];
    if (len == 2) {
        int v = [digits intValue];
        if (v < 10)  return d[(NSUInteger)v];
        if (v == 10) return @"十";
        if (v < 20)  return [NSString stringWithFormat:@"十%@", d[(NSUInteger)(v % 10)]];
        int t = v / 10, o = v % 10;
        return o ? [NSString stringWithFormat:@"%@十%@", d[(NSUInteger)t], d[(NSUInteger)o]]
                 : [NSString stringWithFormat:@"%@十", d[(NSUInteger)t]];
    }
    if (len == 3) {
        int v = [digits intValue];
        if (v % 100 == 0) return [NSString stringWithFormat:@"%@百", d[(NSUInteger)(v / 100)]];
    }
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [digits characterAtIndex:i];
        if (c >= '0' && c <= '9') [s appendString:d[(NSUInteger)(c - '0')]];
    }
    return s;
}
// 返回纠偏后的文本；notes（可传 nil）收集改动摘要，供 UI 提示
static inline NSString* MVTextPolish(NSString *src, NSMutableArray *notes) {
    if (!src.length) return src;
    NSMutableString *out = [NSMutableString stringWithString:src];

    // ① 百分号：先把 "50%" 变成 "百分之50"，让后面的数字规则统一转中文
    NSInteger pct = 0;
    {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+)%"
                                                                          options:0 error:nil];
        NSUInteger m = [re numberOfMatchesInString:out options:0 range:NSMakeRange(0, out.length)];
        if (m) {
            pct = (NSInteger)m;
            [re replaceMatchesInString:out options:0
                                 range:NSMakeRange(0, out.length)
                          withTemplate:@"百分之$1"];
        }
    }
    // ② 符号 → 读法
    NSInteger sym = 0;
    {
        NSArray *pairs = @[@[@"@", @"艾特"], @[@"&", @"和"], @[@"＋", @"加"], @[@"+", @"加"]];
        for (NSArray *p in pairs) {
            while ([out rangeOfString:p[0]].location != NSNotFound) {
                [out replaceCharactersInRange:[out rangeOfString:p[0]] withString:p[1]];
                sym++;
                if (sym > 60) break;
            }
        }
    }
    // ③ 数字 → 中文读法
    NSInteger num = 0;
    {
        NSMutableString *s = [NSMutableString string];
        NSUInteger i = 0, n = out.length;
        while (i < n) {
            unichar c = [out characterAtIndex:i];
            if (c >= '0' && c <= '9') {
                NSUInteger j = i;
                while (j < n) {
                    unichar cj = [out characterAtIndex:j];
                    if (cj >= '0' && cj <= '9') j++; else break;
                }
                [s appendString:MVNumberToChinese([out substringWithRange:NSMakeRange(i, j - i)])];
                num++;
                i = j;
                continue;
            }
            [s appendFormat:@"%C", c];
            i++;
        }
        [out setString:s];
    }
    // ④ 半角标点 → 全角（中文语境更稳；数字此时已转中文，不会误伤小数点）
    {
        NSArray *pairs = @[@[@"!", @"！"], @[@"?", @"？"], @[@",", @"，"], @[@";", @"；"], @[@":", @"："]];
        for (NSArray *p in pairs)
            [out replaceOccurrencesOfString:p[0] withString:p[1]
                                    options:0 range:NSMakeRange(0, out.length)];
    }
    // ⑤ 连续重复标点压缩（。。。→ 。）
    NSInteger rep = 0;
    {
        NSMutableString *s = [NSMutableString string];
        unichar prev = 0;
        for (NSUInteger i = 0; i < out.length; i++) {
            unichar c = [out characterAtIndex:i];
            if (c == prev && MVIsPunctChar(c)) { rep++; continue; }
            [s appendFormat:@"%C", c];
            prev = c;
        }
        [out setString:s];
    }
    // ⑥ 句末补标点（按语气扫一遍关键词，疑问→"?" 感叹→"!" 陈述→"。"）
    //   旧版只补"。"，用户问"怎么不识别疑问/反问/质疑" —— 2.8.8 起按句意图补。
    //   ★ 注意：nxt 可能是 NSNotFound（句末无标点），所以要 length 判断；
    //     否则像 Python `'' in any_string` 那样恒真，C 的 if(...) 也会误判。
    NSInteger qAdded =0, exAdded =0, dotAdded =0;
    {
        NSString *tmp = out;
        // 用一个绝对不会出现在正常文本里的 ASCII 控制字符作分隔符，避开「，。？！」自身的混淆
        unichar sep = 0x01;
        NSString *sepStr = [NSString stringWithCharacters:&sep length:1];
        NSArray *pairs = @[@"，", @"。", @"？", @"！", @"；",
                           @",", @".", @"?", @"!", @";"];
        for (NSString *p in pairs) {
            tmp = [tmp stringByReplacingOccurrencesOfString:p withString:sepStr];
        }
        NSArray *sents = [tmp componentsSeparatedByString:sepStr];
        NSMutableString *rebuilt = [out mutableCopy];
        NSUInteger searchStart = 0;
        for (NSString *raw in sents) {
            if (![raw isKindOfClass:[NSString class]]) continue;
            NSString *sent = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!sent.length) continue;
            NSRange r = [rebuilt rangeOfString:sent options:0 range:NSMakeRange(searchStart, rebuilt.length - searchStart)];
            if (r.location == NSNotFound) continue;
            NSUInteger insertPos = r.location + r.length;
            // ★ 关键：判断"紧接其后的字符是否已经是标点"——必须先 length 判断
            if (insertPos < rebuilt.length) {
                unichar nxt = [rebuilt characterAtIndex:insertPos];
                if (MVIsPunctChar(nxt)) {
                    searchStart = insertPos + 1;
                    continue;
                }
            }
            unichar ending = MVGuessSentenceEnding(sent);
            NSString *mark = [NSString stringWithCharacters:&ending length:1];
            [rebuilt insertString:mark atIndex:insertPos];
            searchStart = insertPos + 1;
            if (ending == 0xFF1F) qAdded++;
            else if (ending == 0xFF01) exAdded++;
            else dotAdded++;
        }
        out = rebuilt;
    }
    // ⑦ 长句断句：连续 24 字没有标点，就在最近的虚词后插逗号
    NSInteger cuts = 0;
    {
        NSString *soft = @"的了是在就都也和给把被要会很还然后又而所以但是";
        NSMutableString *s = [NSMutableString string];
        NSUInteger run = 0;
        for (NSUInteger i = 0; i < out.length; i++) {
            unichar c = [out characterAtIndex:i];
            [s appendFormat:@"%C", c];
            if (MVIsPunctChar(c)) { run = 0; continue; }
            run++;
            if (run >= 24) {
                NSString *ch = [NSString stringWithFormat:@"%C", c];
                if ([soft rangeOfString:ch].location != NSNotFound) {
                    [s appendString:@"，"];
                    run = 0;
                    cuts++;
                }
            }
        }
        [out setString:s];
    }
    if (notes) {
        if (num)      [notes addObject:[NSString stringWithFormat:@"数字转读法 %ld 处", (long)num]];
        if (pct)      [notes addObject:[NSString stringWithFormat:@"百分号转读法 %ld 处", (long)pct]];
        if (sym)      [notes addObject:[NSString stringWithFormat:@"符号转读法 %ld 处", (long)sym]];
        if (rep)      [notes addObject:[NSString stringWithFormat:@"压缩重复标点 %ld 处", (long)rep]];
        if (qAdded)   [notes addObject:[NSString stringWithFormat:@"补问号 %ld 处", (long)qAdded]];
        if (exAdded)  [notes addObject:[NSString stringWithFormat:@"补感叹号 %ld 处", (long)exAdded]];
        if (dotAdded) [notes addObject:[NSString stringWithFormat:@"补句号 %ld 处", (long)dotAdded]];
        if (cuts)     [notes addObject:[NSString stringWithFormat:@"长句断句 %ld 处", (long)cuts]];
    }
    return out;
}

// 千问预置音色（精选常用项；完整 48 个见
// https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list ，
// 面板选不到的可在 设置→我的语音→千问音色 里直接填英文 voice 名，如 Dylan）
static inline NSArray* MVQwenVoiceList(void) {
    return @[
        @{@"name": @"芊悦(女·自然)",   @"voiceID": @"Cherry",   @"model": @"qwen3-tts-flash"},
        @{@"name": @"苏瑶(女·温柔)",   @"voiceID": @"Serena",   @"model": @"qwen3-tts-flash"},
        @{@"name": @"千雪(女·甜)",     @"voiceID": @"Chelsie",  @"model": @"qwen3-tts-flash"},
        @{@"name": @"晨煦(男·阳光)",   @"voiceID": @"Ethan",    @"model": @"qwen3-tts-flash"},
        @{@"name": @"凯(男·舒适)",     @"voiceID": @"Kai",      @"model": @"qwen3-tts-flash"},
        @{@"name": @"阿闻(男·播音)",   @"voiceID": @"Neil",     @"model": @"qwen3-tts-flash"},
        @{@"name": @"不吃鱼(男·随性)", @"voiceID": @"Nofish",   @"model": @"qwen3-tts-flash"},
        @{@"name": @"阿珍(沪语女)",    @"voiceID": @"Jada",     @"model": @"qwen3-tts-flash"},
        @{@"name": @"晓东(京腔男)",    @"voiceID": @"Dylan",    @"model": @"qwen3-tts-flash"},
        @{@"name": @"晴儿(川语女)",    @"voiceID": @"Sunny",    @"model": @"qwen3-tts-flash"},
        @{@"name": @"Jennifer(美语)",  @"voiceID": @"Jennifer", @"model": @"qwen3-tts-flash"},
        @{@"name": @"Ryan(男声)",      @"voiceID": @"Ryan",     @"model": @"qwen3-tts-flash"},
    
        /* 方言音色 */
        @{@"name": @"粤语-阿强(男)",   @"voiceID": @"Rocky",    @"model": @"qwen3-tts-flash"},
        @{@"name": @"粤语-阿清(女)",   @"voiceID": @"Kiki",     @"model": @"qwen3-tts-flash"},
        @{@"name": @"南京-老李(男)",   @"voiceID": @"Li",       @"model": @"qwen3-tts-flash"},
        @{@"name": @"陕西-秦川(男)",   @"voiceID": @"Marcus",   @"model": @"qwen3-tts-flash"},
        @{@"name": @"闽南-阿杰(男)",   @"voiceID": @"Roy",      @"model": @"qwen3-tts-flash"},
        @{@"name": @"天津-李彼得",     @"voiceID": @"Peter",    @"model": @"qwen3-tts-flash"},
        @{@"name": @"四川-程川(男)",   @"voiceID": @"Eric",     @"model": @"qwen3-tts-flash"},
        /* 新增普通音色 */
        @{@"name": @"茉兔(女·搞怪)",   @"voiceID": @"Momo",     @"model": @"qwen3-tts-flash"},
        @{@"name": @"十三(女·自信)",   @"voiceID": @"Vivian",   @"model": @"qwen3-tts-flash"},
        @{@"name": @"月白(女·清冷)",   @"voiceID": @"Moon",     @"model": @"qwen3-tts-flash"},
        @{@"name": @"四月(女·温润)",   @"voiceID": @"Maia",     @"model": @"qwen3-tts-flash"},
        @{@"name": @"萌宝(男·奶萌)",   @"voiceID": @"Bella",    @"model": @"qwen3-tts-flash"},
        @{@"name": @"燕铮莺(男·洪亮)", @"voiceID": @"Bellona",  @"model": @"qwen3-tts-flash"},
        @{@"name": @"田叔(男·沉稳)",   @"voiceID": @"Vincent",  @"model": @"qwen3-tts-flash"},
        @{@"name": @"邻家妹妹(女)",    @"voiceID": @"Nini",     @"model": @"qwen3-tts-flash"},
        @{@"name": @"小婉(女·柔和)",   @"voiceID": @"Seren",    @"model": @"qwen3-tts-flash"},
        @{@"name": @"少女阿月(女)",    @"voiceID": @"Stella",   @"model": @"qwen3-tts-flash"},
];
}

// ★ 2.8.32：这个 voiceID 是不是【千问预置音色】？
//   是预置 → 合成模型听用户在面板选的「千问模型」档位（标准版 / 可调版）；
//   是克隆（myvoice-*）→ 必须用它自己复刻时绑定的 target_model，用户档位管不到它。
//   旧版不分这两种，一律取音色列表里写死的 qwen3-tts-flash ——
//   于是用户选了「可调版」也没用（instructions 永远不生效），"调了没反应"。
static inline BOOL MVIsQwenPresetVoice(NSString *vid) {
    if (!vid.length) return NO;
    for (NSDictionary *d in MVQwenVoiceList())
        if ([d[@"voiceID"] isEqualToString:vid]) return YES;
    return NO;
}

#pragma mark - ★ 2.8.7 千问可调 / 预设 / 模板 / 最近使用 / 友好报错

// ===== 千问(Qwen-TTS)为什么"调了没反应"——官方 2026-09 文档，端点不可混用 =====
//  · Qwen-TTS（qwen3-tts-flash / qwen3-tts-instruct-flash）走
//    dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation，
//    input 只认：text / voice / language_type / instructions / optimize_instructions。
//    → 旧版塞的 input.emotion、input.speed 是【非法字段】，服务端静默忽略；
//      而 qwen3-tts-flash 本身也不支持任何表现参数，只有 qwen3-tts-instruct-flash 认 instructions。
//      这就是"语速滑块没反应、语气段控更没反应"的真因。
//  · CosyVoice / Qwen-Audio-TTS 走 maas 端点，参数名是 instruction（单数、100 字符、汉字算 2）。
//  结论：千问的调节一律走「instructions 自然语言」，没有 rate/pitch/volume 这类数值参数。
static inline NSInteger MVQwenStyle(void) {
    id v = MVGet(@"qwenStyle");
    return v ? [v integerValue] : 0;
}
static inline NSString* MVQwenCustomInstruction(void) { return MVGetStr(@"qwenInstruction"); }
// 千问模型是否认 instructions（只有 qwen3-tts-instruct-flash 系列认）
static inline BOOL MVQwenSupportsInstructions(NSString *model) {
    return [model hasPrefix:@"qwen3-tts-instruct-flash"];
}
static inline NSArray* MVQwenModelChoices(void) {
    return @[@"qwen3-tts-flash", @"qwen3-tts-instruct-flash"];
}
static inline NSString* MVQwenModelLabel(NSString *m) {
    return MVQwenSupportsInstructions(m) ? @"可调版" : @"标准版";
}
// 语速滑块 → 语言描述（千问没有 rate 参数，只能写进指令里）
static inline NSString* MVQwenSpeedPhrase(void) {
    double sp = MVQwenSpeed();
    if (sp <= 0.80) return @"语速放慢，句子之间自然停顿";
    if (sp <= 0.92) return @"语速稍慢一点";
    if (sp >= 1.18) return @"语速稍快一些";
    if (sp >= 1.05) return @"语速轻快";
    return nil;
}
// 千问最终 instructions：强化前缀 + 自定义指令 > 一键风格；语速短语始终叠加
// ★ 2.8.8：强化前缀能让模型更"听指挥"，对千问这种只能写自然语言指令的场景尤其关键。
static inline NSString* MVQwenInstructions(void) {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *prefix = MVReinforcePrefix();
    if (prefix.length) [parts addObject:prefix];
    NSString *custom = MVQwenCustomInstruction();
    if (custom.length) [parts addObject:custom];
    else {
        NSString *st = MVStyleInstruction(MVQwenStyle());
        if (st.length) [parts addObject:st];
    }
    NSString *sp = MVQwenSpeedPhrase();
    if (sp.length) [parts addObject:sp];
    if (!parts.count) return nil;
    NSString *out = [parts componentsJoinedByString:@"，"];
    if (out.length > 300) out = [out substringToIndex:300];   // 官方上限 1600 token，留足余量
    return out;
}

// ===== 预设：音色 + 风格 + 方言 整套切换 =====
static inline NSArray* MVVoicePresets(void) {
    id v = MVGet(@"voicePresets");
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static inline void MVSaveVoicePresets(NSArray *a) { MVSetShared(@"voicePresets", a ?: @[]); }
// 抓当前面板状态成一个预设
static inline NSDictionary* MVCaptureVoicePreset(NSString *name) {
    NSInteger prov = MVTTSProvider();
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"name"] = name.length ? name : @"未命名";
    p[@"provider"] = @(prov);
    if (prov == 1) {
        p[@"qwenVoice"]   = MVQwenVoice();
        p[@"qwenModel"]   = MVQwenModel();
        p[@"style"]       = @(MVQwenStyle());
        p[@"instruction"] = MVQwenCustomInstruction() ?: @"";
        p[@"qwenSpeed"]   = @(MVQwenSpeed());
    } else {
        p[@"voiceID"]     = MVGetStr(@"currentVoiceID");   // 直接读键：MVCurrentVoiceID 定义在本块之后
        p[@"style"]       = @(MVCosyStyle());
        p[@"dialect"]     = MVGetStr(@"cosyDialect") ?: @"";
        p[@"instruction"] = MVGetStr(@"cosyInstruction") ?: @"";
        p[@"rate"]        = @(MVCosyRate());
        p[@"pitch"]       = @(MVCosyPitch());
    }
    return p;
}
// 应用一个预设（整套写回）
static inline void MVApplyVoicePreset(NSDictionary *p) {
    if (![p isKindOfClass:[NSDictionary class]]) return;
    NSInteger prov = [p[@"provider"] integerValue];
    // ★ 2.8.35：预设里的 provider 映射到三通道（ttsProvider 已不再直接生效）
    //   provider=1（千问）→ 通道2；provider=0（克隆）→ 当前是自建通道就保持 0，否则通道1
    MVSetShared(@"ttsChannel", @(prov == 1 ? 2 : (MVChannel() == 0 ? 0 : 1)));
    if (prov == 1) {
        if ([p[@"qwenVoice"] length]) MVSetShared(@"qwenVoice", p[@"qwenVoice"]);
        if ([p[@"qwenModel"] length]) MVSetShared(@"qwenModel", p[@"qwenModel"]);
        if (p[@"style"])       MVSetShared(@"qwenStyle", p[@"style"]);
        if (p[@"instruction"]) MVSetShared(@"qwenInstruction", p[@"instruction"]);
        if (p[@"qwenSpeed"])   MVSetShared(@"qwenSpeed", p[@"qwenSpeed"]);
    } else {
        if ([p[@"voiceID"] length]) MVSetShared(@"currentVoiceID", p[@"voiceID"]);
        if (p[@"style"]) MVSetShared(@"cosyStyle", p[@"style"]);
        MVSetShared(@"cosyDialect", p[@"dialect"] ?: @"");
        MVSetShared(@"cosyInstruction", p[@"instruction"] ?: @"");
        if (p[@"rate"])  MVSetShared(@"cosyRate", p[@"rate"]);
        if (p[@"pitch"]) MVSetShared(@"cosyPitch", p[@"pitch"]);
    }
}

// ===== 常用文本模板 =====
static inline NSArray* MVDefaultTemplates(void) {
    return @[
        @{@"title": @"稍后回你", @"text": @"稍等，我在忙，一会儿回你"},
        @{@"title": @"收到",     @"text": @"收到，马上处理"},
        @{@"title": @"好的",     @"text": @"好的，没问题"},
        @{@"title": @"马上到",   @"text": @"我马上到"},
        @{@"title": @"改天吧",   @"text": @"今天不方便，改天吧"},
    ];
}
static inline NSArray* MVTextTemplates(void) {
    id v = MVGet(@"textTemplates");
    if ([v isKindOfClass:[NSArray class]] && [v count]) return v;
    return MVDefaultTemplates();
}
static inline void MVSaveTextTemplates(NSArray *a) { MVSetShared(@"textTemplates", a ?: @[]); }

// ===== 最近使用（MRU，最多 12 个 voiceID）=====
static inline NSArray* MVRecentVoices(void) {
    id v = MVGet(@"recentVoices");
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static inline void MVMarkVoiceUsed(NSString *vid) {
    if (!vid.length) return;
    NSMutableArray *a = [NSMutableArray arrayWithArray:MVRecentVoices()];
    [a removeObject:vid];
    [a insertObject:vid atIndex:0];
    while (a.count > 12) [a removeLastObject];
    MVSetShared(@"recentVoices", a);
}

// ===== 友好报错：把 DashScope 的 code / HTTP 码翻成"人话 + 怎么办" =====
static inline NSString* MVFriendlyAPIError(NSInteger code, NSString *body, NSString *stage) {
    NSString *raw = body ?: @"";
    NSString *errCode = @"";
    NSString *errMsg  = @"";
    NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
    if (d.length) {
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([j isKindOfClass:[NSDictionary class]]) {
            if ([j[@"code"] isKindOfClass:[NSString class]])    errCode = j[@"code"];
            if ([j[@"message"] isKindOfClass:[NSString class]]) errMsg  = j[@"message"];
        }
    }
    NSString *why = nil;
    // ★ 2.8.32：官方错误码文档「原因一：模型名称与 API 端点不匹配」。
    //   Qwen-TTS(qwen3-tts-*) → multimodal-generation/generation；
    //   Qwen-Audio-TTS(qwen-audio-3.0-tts-*) / CosyVoice → /services/audio/tts/SpeechSynthesizer。
    //   必须放在下面那条泛化的「model + 400」之前，否则会被吞掉成"模型名不支持"。
    if ([errMsg rangeOfString:@"url error" options:NSCaseInsensitiveSearch].location != NSNotFound)
        why = @"模型与接口端点不匹配（该模型不在这条通道上：\n"
              @"qwen3-tts-* 走 multimodal-generation，qwen-audio-3.0-tts-* / cosyvoice-* 走 audio/tts；\n"
              @"若当前是「克隆」音色，它锁定了自己的模型与端点，换成预置音色即可）";
    else if ([errCode containsString:@"InvalidApiKey"] || code == 401)
        why = @"API Key 无效或已失效（去 设置→我的语音 重填北京地域的 DashScope Key）";
    else if ([raw containsString:@"Free quota"] || [raw containsString:@"use free tier only"] ||
             [raw containsString:@"exhausted"] || [raw containsString:@"paid basis"] || [raw containsString:@"add funds"])
        why = @"该模型免费额度已耗尽（DashScope 默认仅免费层模式）。去百炼控制台(bailian.console.aliyun.com)给该模型开通按量付费，或账户充值，并关闭「Use free tier only」开关";
    else if ([errCode containsString:@"AccessDenied"] || [errCode containsString:@"Model.AccessDenied"] || code == 403)
        why = @"该模型没有权限（去百炼控制台开通对应模型，或换一个模型）";
    else if ([errCode containsString:@"Arrearage"])
        why = @"账户欠费或免费额度用尽（去百炼控制台充値）";
    else if ([errCode containsString:@"Throttling"] || code == 429)
        why = @"调用太频繁（等几秒再试）";
    else if ([errCode containsString:@"DataInspection"])
        why = @"内容审核未通过（换成正常说话的文字或音频）";
    else if ([errCode containsString:@"UnsupportedModel"] || ([errMsg containsString:@"model"] && code == 400))
        why = @"模型名不支持（在「标准版 / 可调版」之间换一个试试）";
    else if (code == 400)
        why = @"参数不合规（音色、模型或参考音频不符合官方要求）";
    else if (code == 404)
        why = @"接口路径不存在（多为地域不对：本插件需用北京地域的 Key）";
    else if (code >= 500)
        why = @"服务端临时故障（稍后重试）";
    else
        why = [NSString stringWithFormat:@"服务端拒绝（HTTP %ld）", (long)code];
    NSString *tail = errMsg.length ? errMsg : raw;
    if (tail.length > 200) tail = [tail substringToIndex:200];
    return [NSString stringWithFormat:@"%@：%@%@", stage ?: @"失败", why,
            tail.length ? [NSString stringWithFormat:@"\n服务端原文：%@", tail] : @""];
}

// ===== PCM → WAV（列表内试听要用 AVAudioPlayer 播，必须带容器头）=====
static inline void MVAppendLE32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
                     (uint8_t)((v >> 16) & 0xFF), (uint8_t)((v >> 24) & 0xFF) };
    [d appendBytes:b length:4];
}
static inline void MVAppendLE16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF) };
    [d appendBytes:b length:2];
}
static inline NSData* MVWavFromPCM(NSData *pcm, uint32_t sr, uint16_t ch, uint16_t bits) {
    if (!pcm.length) return nil;
    NSMutableData *o = [NSMutableData dataWithCapacity:pcm.length + 44];
    [o appendBytes:"RIFF" length:4];
    MVAppendLE32(o, (uint32_t)(36 + pcm.length));
    [o appendBytes:"WAVEfmt " length:8];
    MVAppendLE32(o, 16);
    MVAppendLE16(o, 1);                       // PCM
    MVAppendLE16(o, ch);
    MVAppendLE32(o, sr);
    MVAppendLE32(o, sr * ch * bits / 8);
    MVAppendLE16(o, (uint16_t)(ch * bits / 8));
    MVAppendLE16(o, bits);
    [o appendBytes:"data" length:4];
    MVAppendLE32(o, (uint32_t)pcm.length);
    [o appendData:pcm];
    return o;
}

// DashScope（北京地域）凭证
static inline NSString* MVAPIKey(void)     { return MVGetStr(@"apiKey"); }
static inline NSString* MVWorkspace(void)  { return MVGetStr(@"workspace"); }

// 多音色列表：@[@{name, voiceID, model}]
// ★ 2.8.13：克隆音色必须跨 App 共享（微信克隆 → QQ 也显示）。
//   旧实现 MVGet 容器优先：微信把克隆写进自己沙盒容器，QQ 读自己空容器就返回空，
//   于是「微信克隆、QQ 看不到」。改为优先读全局共享域（CFPreferences 全局域 +
//   jbroot 共享 plist），再并入本 App 容器的值（按 voiceID 去重）。
static inline NSArray* MVVoices(void) {
    NSMutableArray *out = [NSMutableArray array];
    // ① 全局域（kCFPreferencesAnyUser）—— 各 App 都能读到，最稳的跨 App 通道
    CFPropertyListRef gv = CFPreferencesCopyValue((__bridge CFStringRef)@"voices",
        (__bridge CFStringRef)MV_PREFS_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    if (gv) {
        NSArray *a = CFBridgingRelease(gv);
        if ([a isKindOfClass:[NSArray class]]) [out addObjectsFromArray:a];
    }
    // ② jbroot 共享 plist
    NSDictionary *shared = MVSharedPrefs();
    NSArray *sv = shared[@"voices"];
    if ([sv isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in sv) {
            BOOL dup = NO;
            for (NSDictionary *e in out) if ([e[@"voiceID"] isEqualToString:d[@"voiceID"]]) { dup = YES; break; }
            if (!dup) [out addObject:d];
        }
    }
    // ③ 本 App 容器（刚保存的本地副本），并入去重
    id cv = [MVPrefs() objectForKey:@"voices"];
    if ([cv isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in (NSArray*)cv) {
            BOOL dup = NO;
            for (NSDictionary *e in out) if ([e[@"voiceID"] isEqualToString:d[@"voiceID"]]) { dup = YES; break; }
            if (!dup) [out addObject:d];
        }
    }
    return out.count ? out : @[];
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

// ★ 2.8.4：复刻（克隆）统一使用的 target_model。
//   旧实现用 MVCurrentModel() —— 那是「当前选中音色」的 model，可能指向别的音色/别的版本，
//   新复刻出来的 voice_id 会绑到一个意外的模型上，合成时 model 对不上 → 报错或退回旧音色。
static inline NSString* MVCosyModel(void) {
    NSString *v = MVGetStr(@"cosyModel");
    return v.length ? v : @"cosyvoice-v3.5-plus";
}

// ★ 2.8.4：按 voiceID 反查该音色绑定的 model。
//   CosyVoice 的 voice_id 与复刻时的 target_model 强绑定，合成必须用同一个 model，否则会失败。
//   取不到就退回统一的复刻模型（MVCosyModel）。
static inline NSString* MVModelForVoice(NSString *voiceID) {
    if (voiceID.length) {
        // ★ 2.8.30：预置千问音色也在 MVQwenVoiceList 里，必须先查，
        //   否则预置音色会漏到 cosyvoice 默认模型 → 千问预置声线错乱。
        for (NSDictionary *d in MVQwenVoiceList()) {
            if ([d[@"voiceID"] isEqualToString:voiceID]) {
                NSString *m = d[@"model"];
                if ([m isKindOfClass:[NSString class]] && m.length) return m;
            }
        }
        for (NSDictionary *d in MVVoices()) {
            if ([d[@"voiceID"] isEqualToString:voiceID]) {
                NSString *m = d[@"model"];
                if ([m isKindOfClass:[NSString class]] && m.length) return m;
            }
        }
    }
    return (MVTTSProvider()==1) ? MVQwenModel() : MVCosyModel();
}

// OSS（克隆音色时一次性托管参考音频，拿公网 URL 给 DashScope）
static inline NSString* MVOSSBucket(void)   { return MVGetStr(@"ossBucket"); }
static inline NSString* MVOSSHost(void)     { return MVGetStr(@"ossHost"); }   // 形如 oss-cn-hangzhou.aliyuncs.com
static inline NSString* MVOSSAk(void)       { return MVGetStr(@"ossAk"); }
static inline NSString* MVOSSSk(void)       { return MVGetStr(@"ossSk"); }

// 触发方式：0 = 悬浮按钮（默认）；1 = 长按录音键
static inline NSInteger MVTrigger(void){ id v = MVGet(@"trigger"); return v ? [v integerValue] : 0; }

// 自动发送：装填完成后自动模拟「按住说话」并在 TTS 时长后自动松手，免去手动按住
// （默认开启；自动触发若未生效会自动回退成手动提示，绝不会比现在更差）
static inline NSInteger MVAutoSend(void){ id v = MVGet(@"autoSend"); return v ? [v boolValue] : YES; }

// ---- UI 线程安全（2.0.15 修的崩溃）----
// 引擎合成回调【一定不在主线程】：
//   · 离线 AVSpeech 引擎：dispatch_get_global_queue(QOS_CLASS_DEFAULT) 上跑（队列名 com.apple.root.default-qos）
//   · 云端 CosyVoice 引擎：NSURLSession 的 completionHandler 上跑
// 这些回调里的任一 UIKit 调用（哪怕只是 [window addSubview:]）都会触发 CoreAutoLayout 的
//   _AssertAutoLayoutOnAllowedThreadsOnly 断言 → 抛 NSException → 微信的 uncaught handler → abort()
// 实测崩溃栈：AVSEngine -synthesizeText: → Sender(block) → Manager -toast: → WeChat swizzled -addSubview: → 💥
// 所以：凡是从回调/后台队列能碰到的 UI 路径，一律先过 MVOnMain。
static inline void MVOnMain(dispatch_block_t blk) {
    if (!blk) return;
    if ([NSThread isMainThread]) blk();
    else dispatch_async(dispatch_get_main_queue(), blk);
}

// ---- 微信内部服务/工具（2.0.17 直发链路用）----

// ============================================================
// ★★★ 2.2.8 关键修复：宿主就绪探针 ★★★
//
// 【崩溃现场】iOS 16.6 / 微信 8.0.75.33 / MyVoice 2.2.7，主线程 SIGSEGV：
//   EXC_BAD_ACCESS (KERN_INVALID_ADDRESS at 0x90)，selector = sharedInstance
//   dyld → MyVoice.dylib initializer(offset 0x80F0) → -[MyVoiceManager setup]
//        → -[MyVoicePanel show] → -[MyVoiceResolver currentTalker]
//        → MVService / NSClassFromString → WeChat +initialize
//        → _dispatch_once_callout → +sharedInstance → 💥
//
// 【为什么会崩】本 tweak 由 RootHide 的 TweakInject 在**微信进程 dyld 初始化期**就
//   dlopen 并执行 %ctor。那一刻微信自己的 ObjC 类尚未 realize、+initialize 还没跑。
//   此时只要执行一次 NSClassFromString(@"MMServiceCenter")（或任何宿主类名），就会把
//   该宿主类**强行 realize 并触发它的 +initialize**；而微信 +initialize 内部会去取
//   尚未就绪的单例 → 拿到野指针 → 0x90 处访存 → 崩。
//
// 【判据】UIApplication 是系统类：UIApplicationMain 之前 +sharedApplication 恒返回 nil，
//   且「给 nil 发消息」在 ObjC 里是安全的。所以它是唯一能安全使用的就绪探针。
//   ⚠️ 绝不能用 NSClassFromString(宿主类) 做判定 —— 那本身就是引爆器。
// ============================================================
static inline BOOL MVHostReady(void) {
    Class appCls = objc_getClass("UIApplication");
    if (!appCls) return NO;
    SEL s = NSSelectorFromString(@"sharedApplication");
    if (!s || ![appCls respondsToSelector:s]) return NO;
    id app = ((id(*)(id,SEL))objc_msgSend)((id)appCls, s);
    return app != nil;
}

// 取微信服务实例（CMessageMgr / CContactMgr / ...）：
// 首选 MMServiceCenter.defaultCenter → getService:<cls>，退化到 sharedInstance。
static inline id MVService(NSString *clsName) {
    // ★ 2.2.8：宿主未就绪时绝不 resolve 宿主类名，否则触发其 +initialize 直接崩。
    if (!MVHostReady()) { MVLog(@"[svc] 宿主未就绪，跳过取 %@", clsName); return nil; }
    Class cls = NSClassFromString(clsName);
    if (!cls) return nil;
    @try {
        Class sc = NSClassFromString(@"MMServiceCenter");
        if (sc) {
            SEL dc = NSSelectorFromString(@"defaultCenter");
            if ([sc respondsToSelector:dc]) {
                id center = ((id(*)(id,SEL))objc_msgSend)(sc, dc);
                SEL gs = NSSelectorFromString(@"getService:");
                if (center && [center respondsToSelector:gs]) {
                    id svc = ((id(*)(id,SEL,id))objc_msgSend)(center, gs, cls);
                    if (svc) return svc;
                }
            }
        }
        SEL si = NSSelectorFromString(@"sharedInstance");
        if ([cls respondsToSelector:si]) return ((id(*)(id,SEL))objc_msgSend)(cls, si);
    } @catch (NSException *e) {
        MVLog(@"[svc] 取 %@ 实例异常 %@", clsName, e.reason);
    }
    return nil;
}

// 无参数、有返回值的消息发送（避免到处写 objc_msgSend 强转）
static inline id MVCall0(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj, s);
}
static inline id MVCall1(id obj, NSString *sel, id a1) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL,id))objc_msgSend)(obj, s, a1);
}
static inline void MVCallVoid2(id obj, NSString *sel, id a1, id a2) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return;
    ((void(*)(id,SEL,id,id))objc_msgSend)(obj, s, a1, a2);
}
// 第一个参数是整型的那种（AddMsg:MsgWrap: 可能如此）
static inline void MVCallVoidIntObj(id obj, NSString *sel, long long a1, id a2) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return;
    ((void(*)(id,SEL,long long,id))objc_msgSend)(obj, s, a1, a2);
}
// 给对象设一个整型字段（CMessageWrap 的 m_uiCreateTime / m_uiMesLocalID 等都是 I=unsigned int）
static inline void MVSetInt(id obj, NSString *sel, unsigned int v) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return;
    ((void(*)(id,SEL,unsigned int))objc_msgSend)(obj, s, v);
}
// 取一个返回 uint 的方法（如 getVoiceFormat）
static inline unsigned int MVGetUInt(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return 0;
    return ((unsigned int(*)(id,SEL))objc_msgSend)(obj, s);
}
// 布尔方法（fileExistsAtPath: / writeToFile:atomically: 等）
static inline BOOL MVGetBool1(id obj, NSString *sel, id a1) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return NO;
    return ((BOOL(*)(id,SEL,id))objc_msgSend)(obj, s, a1);
}
static inline BOOL MVGetBool2(id obj, NSString *sel, id a1, BOOL a2) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return NO;
    return ((BOOL(*)(id,SEL,id,BOOL))objc_msgSend)(obj, s, a1, a2);
}

// ★ 2.8.28：按 voiceID 自身所属服务商路由（不再依赖全局 ttsProvider）。
//   选中克隆/设计音色就走 CosyVoice，选中千问预置就走 Qwen；
//   彻底根治「选中克隆音色却因全局开关错位而发出普通话」。
//   注意：必须放在 MVQwenVoiceList / MVVoices 声明之后（C 要求先声明后使用）。
static inline NSInteger MVVoiceProvider(NSString *vid) {
    if (!vid.length) return MVTTSProvider();
    // ★ 2.8.30：按音色【真实绑定的模型】路由，而不是 provider 字段。
    //   旧版把千问克隆(myvoice-xxxx, 模型 qwen-audio-3.0-tts-plus)的 provider 写成 0(CosyVoice)，
    //   合成却走了 CosyVoice 路径、喂了 qwen-audio 模型 → 音色不匹配 → 退回普通话。
    //   现在：模型含 cosyvoice → CosyVoice 路径；含 qwen → 千问路径。彻底按"选哪个音色发哪个"。
    NSString *m = MVModelForVoice(vid);
    if ([m rangeOfString:@"cosyvoice" options:NSCaseInsensitiveSearch].location != NSNotFound) return 0;
    if ([m rangeOfString:@"qwen"      options:NSCaseInsensitiveSearch].location != NSNotFound) return 1;
    // 兜底：按 provider 字段 / 全局开关
    for (NSDictionary *d in MVQwenVoiceList())
        if ([d[@"voiceID"] isEqualToString:vid]) return 1;
    for (NSDictionary *d in MVVoices())
        if ([d[@"voiceID"] isEqualToString:vid]) return ([d[@"provider"] integerValue] == 1) ? 1 : 0;
    return MVTTSProvider();
}


// ===== ★ 2.8.33 新增 / ★ 2.8.34 调整：自建服务器（本地 CosyVoice + ECS 中转，免费克隆音色）=====
//   开关/地址/令牌：开启后，CosyVoice 族（克隆 / 设计 / 预置）全部走本地 server.py，
//   不再消耗 DashScope 额度；千问预置音色仍走阿里云。
//
//   ★ 2.8.34 关键：这三个键【只由「系统设置 → 我的语音」写入】（落 jbroot 共享域）。
//   为什么不能沿用 MVGet 的默认顺序：MVGet 是【容器 suite 优先】（见上文 2.4.3 的说明），
//   而 Settings 进程写不到微信容器 —— 设置页改的值会被容器里的旧值遮住，表现为
//   「设置页改了不生效」。历史上 ttsProvider / qwenVoice 就是这么被坑的。
//   所以自建键单独走【jbroot 共享域优先】，顺带自愈 2.8.33 残留在容器里的旧值。
//   ⚠️ 前提：面板（微信进程内）【不能再写这三个键】，否则又会被容器遮住。
//      → 面板已改为只读状态提示（见 MyVoicePanel 的 showSelfHostInfo）。
static inline id MVSelfHostGet(NSString *key) {
    NSDictionary *sh = MVSharedPrefs();
    if ([sh isKindOfClass:[NSDictionary class]]) {
        id v = sh[key];
        if (v) return v;
    }
    return MVGet(key);
}
// ★ 2.8.35：自建服务器不再是独立开关，而是 ttsChannel==0 的派生结果。
//   与「云端千问」天然互斥：选了千问通道，这里必然是 NO；选了自建通道，千问一定不参与。
static inline BOOL MVSelfHostEnabled(void) { return MVChannel() == 0; }
static inline NSString* MVSelfHostURL(void) {
    id raw = MVSelfHostGet(@"selfHostURL");
    NSString *v = [raw isKindOfClass:[NSString class]] ? raw : (raw ? [raw description] : @"");
    if (!v.length) return @"http://127.0.0.1:8000";   // 默认本机调试（手机与服务器同网 / 隧道）
    // ★ 2.8.36：用户常只填 ip:port（如 101.200.189.251:18000）漏掉 http://，
    //   导致 NSURL 解析失败、合成报「不支持的URL」。这里统一兜底补 scheme。
    if (![v hasPrefix:@"http://"] && ![v hasPrefix:@"https://"])
        v = [@"http://" stringByAppendingString:v];
    if ([v hasSuffix:@"/"]) v = [v substringToIndex:v.length - 1];
    return v;
}
static inline NSString* MVSelfHostToken(void) {
    id raw = MVSelfHostGet(@"selfHostToken");
    return [raw isKindOfClass:[NSString class]] ? raw : (raw ? [raw description] : @"");
}

// ★ 2.8.37：自建服务器「同步服务器音色」—— 把电脑上 server.py 的 voices/ 语音包与模型预置音色
//   拉到手机列表里。只存元数据（id/label），参考音频永远留在服务器；
//   合成时发 voice=<id>，服务端自己读 voices/<id>/ref.wav。
static inline NSArray* MVServerVoices(void) {
    NSDictionary *sh = MVSharedPrefs();
    id v = [sh isKindOfClass:[NSDictionary class]] ? sh[@"selfHostVoices"] : nil;
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
static inline void MVSetServerVoices(NSArray *a) {
    MVSetShared(@"selfHostVoices", a ?: @[]);
}

// ★ 克隆音色复刻时把参考音频存到本机沙盒；合成时作为 ref_audio_b64 发给 server.py 做零样本复刻。
static inline NSString* MVSelfHostRefAudioDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/myvoice_selfhost_refs"];
}
static inline NSString* MVSelfHostRefAudioPath(NSString *voiceID) {
    if (!voiceID.length) return nil;
    return [MVSelfHostRefAudioDir() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.wav", voiceID]];
}
static inline NSData* MVSelfHostRefAudioForVoice(NSString *voiceID) {
    NSString *p = MVSelfHostRefAudioPath(voiceID);
    if (!p) return nil;
    return [NSData dataWithContentsOfFile:p];
}
static inline void MVSelfHostSaveRefAudio(NSString *voiceID, NSData *audio) {
    if (!voiceID.length || !audio.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:MVSelfHostRefAudioDir()
      withIntermediateDirectories:YES attributes:nil error:nil];
    [audio writeToFile:MVSelfHostRefAudioPath(voiceID) atomically:NO];
}
