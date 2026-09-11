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

// 微信录音管线实测采样率：**16kHz / 单声道 / S16**（2.1.0 起改用录音管线劫持后校正）。
// 证据：AudioQueueNewInput 申请格式 + 实测 buffer 8000B/250ms（= 32000 B/s = 16000 Hz × 2B）。
// ⚠️ 2.0.17 之前这里写的是 24000（当时是"自己编码 SILK 再直发"的推测值），
//    改成录音管线劫持后必须以管线真实采样率为准，否则音调/时长会错位。
#define MV_WECHAT_SR 16000.0

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
static inline NSInteger MVTTSProvider(void){ id v = MVGet(@"ttsProvider"); return v ? [v integerValue] : 0; }

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

// OSS（克隆音色时一次性托管参考音频，拿公网 URL 给 DashScope）
static inline NSString* MVOSSBucket(void)   { return MVGetStr(@"ossBucket"); }
static inline NSString* MVOSSHost(void)     { return MVGetStr(@"ossHost"); }   // 形如 oss-cn-hangzhou.aliyuncs.com
static inline NSString* MVOSSAk(void)       { return MVGetStr(@"ossAk"); }
static inline NSString* MVOSSSk(void)       { return MVGetStr(@"ossSk"); }

// 触发方式：0 = 悬浮按钮（默认）；1 = 长按录音键
static inline NSInteger MVTrigger(void){ id v = MVGet(@"trigger"); return v ? [v integerValue] : 0; }

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

// 取微信服务实例（CMessageMgr / CContactMgr / ...）：
// 首选 MMServiceCenter.defaultCenter → getService:<cls>，退化到 sharedInstance。
static inline id MVService(NSString *clsName) {
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
