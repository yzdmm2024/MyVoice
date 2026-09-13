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

// 云端 TTS 服务商：0 = CosyVoice（克隆/设计音色）；1 = 千问 Qwen-TTS（官方预置音色，无需克隆）
// 注意：同一个 DashScope API Key 两边通用，切换时不用换 Key。
// 2.2.1 起默认改为千问，避免新用户没克隆音色时直接合成失败。
static inline NSInteger MVTTSProvider(void){ id v = MVGet(@"ttsProvider"); return v ? [v integerValue] : 1; }

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
static inline NSArray* MVCosyStyleNames(void) {
    return @[@"默认", @"人情味", @"标准腔", @"慢语速", @"亲切", @"活泼"];
}
// instruction：自定义指令优先，其次按一键风格取预设；返回 nil 表示不传
static inline NSString* MVCosyInstruction(void) {
    NSString *custom = MVGetStr(@"cosyInstruction");
    if (custom.length) return custom;
    switch (MVCosyStyle()) {
        case 1: return @"用自然随意的日常聊天语气说，像跟朋友发语音一样，语速自然，不要播音腔";
        case 2: return @"用标准播报腔，字正腔圆，语气平稳，吐字清晰";
        case 3: return @"语速放慢，吐字清晰，句子之间自然停顿";
        case 4: return @"语气温和亲切，像长辈在关心人，语速舒缓";
        case 5: return @"语气活泼俏皮，带一点笑意，节奏轻快";
        default: return nil;
    }
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
// instruction 只有 v3.5-flash / v3.5-plus / v3-flash 支持；其它模型传了会 400
static inline BOOL MVCosySupportsInstruction(NSString *model) {
    if (!model.length) return NO;
    if ([model hasPrefix:@"cosyvoice-v3.5-"]) return YES;
    if ([model isEqualToString:@"cosyvoice-v3-flash"]) return YES;
    return NO;
}

// ===== ★ 2.8.5：文本「一键纠偏」（纯本地规则，零网络） =====
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
    // ⑥ 句末补标点（没标点的长句会被 TTS 读成"一口气念完"）
    BOOL addedEnd = NO;
    {
        unichar last = [out length] ? [out characterAtIndex:out.length - 1] : 0;
        if (last && !MVIsPunctChar(last)) { [out appendString:@"。"]; addedEnd = YES; }
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
        if (addedEnd) [notes addObject:@"补句末标点"];
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
        for (NSDictionary *d in MVVoices()) {
            if ([d[@"voiceID"] isEqualToString:voiceID]) {
                NSString *m = d[@"model"];
                if ([m isKindOfClass:[NSString class]] && m.length) return m;
            }
        }
    }
    return MVCosyModel();
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
