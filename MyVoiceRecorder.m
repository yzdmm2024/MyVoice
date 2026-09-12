#import "MyVoiceRecorder.h"
#import "MyVoiceCommon.h"
#import <AudioToolbox/AudioToolbox.h>

// MSHookFunction（substrate / ellekit 都提供同名 C 符号）。
// 刻意不 include substrate.h：rootless 环境里那个头的路径在各家实现下不一致，
// 直接声明原型最省事，链接由 theos 的 tweak.mk 自动带上 -lsubstrate。
extern void MSHookFunction(void *symbol, void *hook, void **old);

// ============================================================
// 状态（全部读写都过 @synchronized([NSObject class])，与音频实时回调互斥）
// ============================================================

// 主档 PCM：固定 16kHz(MV_WECHAT_SR) 单声道 S16。
// 2.2.0 起装填时不再直接重采样到"管线采样率"——微信进程里可能有多个 AudioQueue 录音
// 队列（语音消息录音器、音色克隆的 AVAudioRecorder、VoIP…），最终由哪个队列消费要等
// 回调发生才知道，重采样推迟到回调里按消费队列的采样率做一次。
static NSData   *g_mvFeed        = nil;  // 主档：16k S16
static BOOL      g_mvArmed       = NO;   // 替换开关
static NSTimeInterval g_mvArmAt  = 0;    // 装填时刻（用于超时自动取消）

// ---- 每队列登记（2.2.0 修复；2.2.4 起偏移也下放到队列）----
// 旧版只认进程里第一个创建的 AudioQueue 录音回调并永久绑定。如果「音色管理→录音复刻」
// 的 AVAudioRecorder（24kHz，同样在微信进程里走 AudioQueue）先建队列，登记的采样率和
// 回调就全错了，真正的「按住说话」录音器反而永远不会被替换 → 发出去的是麦克风原声。
// 2.2.0 改为每个输入队列独立登记（回调 + 采样率），替换与原回调转发按 inAQ 精确匹配。
//
// ★ 2.2.4 修「语音有回音 / 听起来两个声音」：
//   2.2.0~2.2.3 虽然按队列登记了回调，但**喂入偏移 g_mvOff 是全局共享的一份**。
//   若同时存在两个输入队列（例如微信语音录音器 + 另一个输入队列/AEC 参考通道），
//   两个队列的回调会互相抢食同一份 TTS：
//     · 每次采样率不同就 g_mvOff=0 重来 → 同一段 TTS 被反复从头播放（叠音/回声）；
//     · 两个队列交替推进偏移 → 每个队列拿到的是被挖空的片段（断续、不自然）。
//   现在把「已喂偏移 / 重采样副本」都下放到每个队列，各队列各自从 0 完整消费一份 TTS，
//   互不干扰 → 不会叠音、不会断续。
typedef struct {
    AudioQueueRef           aq;
    AudioQueueInputCallback cb;
    double                  rate;
    UInt32                  ch;
    NSUInteger              off;          // 本队列已消费的 TTS 字节（相对本队列重采样副本）
    BOOL                    loggedStart;  // 本队列是否已打过"开始替换"日志
} MVQueueEntry;
#define MV_MAX_QUEUES 8
static MVQueueEntry g_mvQueues[MV_MAX_QUEUES];
static NSInteger    g_mvQueueCount = 0;

// 每个队列专用的重采样副本（与 g_mvQueues 同下标；末位 MV_SLOT_FALLBACK 给未登记队列）
#define MV_SLOT_FALLBACK MV_MAX_QUEUES
static MVQueueEntry g_mvFallback;                       // 没登记过的队列走这里（自带一份偏移）
static NSData  *g_mvQRes[MV_MAX_QUEUES + 1];
static double   g_mvQResRate[MV_MAX_QUEUES + 1];

static double     g_mvPipeRate  = 0;     // 最近登记的队列采样率（诊断/日志用）
static UInt32     g_mvPipeCh    = 0;     // 声道数
static BOOL       g_mvFmtLogged = NO;
static NSUInteger g_mvCbSeq     = 0;     // 回调序号（诊断）

static OSStatus (*g_mvOrigAQNewInput)(const AudioStreamBasicDescription*, AudioQueueInputCallback,
                                      void*, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef*) = NULL;
static OSStatus (*g_mvOrigAQNewInputDisp)(AudioQueueRef*, const AudioStreamBasicDescription*,
                                          UInt32, dispatch_queue_t,
                                          AudioQueueInputCallback) = NULL;

static BOOL g_mvHooked = NO;

// 装填后多久没被消费就自动取消（避免一直劫持麦克风）
static const NSTimeInterval kMVArmTimeout = 120.0;

static MVQueueEntry* MVQueueForAQ(AudioQueueRef aq) {
    MVQueueEntry *fallback = NULL;
    for (NSInteger i = 0; i < g_mvQueueCount; i++) {
        if (g_mvQueues[i].aq == aq) return &g_mvQueues[i];
        // aq==NULL 的占位项 = 经由拿不到队列句柄的入口创建，精确匹配失败时回退用它
        if (g_mvQueues[i].aq == NULL && !fallback) fallback = &g_mvQueues[i];
    }
    return fallback;
}

#pragma mark - 重采样（S16 单声道，线性插值）

static NSData* MVResampleS16(NSData *src, double srcRate, double dstRate) {
    if (!src.length || srcRate <= 0 || dstRate <= 0) return nil;
    if (fabs(srcRate - dstRate) < 1.0) return src;      // 同采样率直接原样用

    NSUInteger nSrc = src.length / 2;
    if (!nSrc) return nil;
    double ratio = dstRate / srcRate;
    NSUInteger nDst = (NSUInteger)((double)nSrc * ratio);
    if (!nDst) return nil;

    const short *in = (const short*)src.bytes;
    NSMutableData *out = [NSMutableData dataWithLength:nDst * 2];
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
    MVLog(@"[rec] 重采样 %.0fHz → %.0fHz：%lu → %lu 样本",
          srcRate, dstRate, (unsigned long)nSrc, (unsigned long)nDst);
    return out;
}

#pragma mark - 音频回调 trampoline

// 策略（照搬已被验证的「整块填满」）：
//   每次回调把整块 buffer 用连续的 TTS 字节填满 —— 块内绝不留缝隙。
//   （曾经的「按实测速率节奏喂」会在 TTS 流与 buffer 流之间产生零填充间隙，
//     结果每 250ms 插一段静音 = 明显杂音，已废弃。）
//   TTS 耗尽后整块补零，保持录音会话的节奏直到用户松手。
static void MV_AQInputTrampoline(void *inUserData, AudioQueueRef inAQ,
                                 AudioQueueBufferRef inBuffer,
                                 const AudioTimeStamp *inStartTime,
                                 UInt32 inNumberPacketDescriptions,
                                 const AudioStreamPacketDescription *inPacketDescs) {
    AudioQueueInputCallback origCb = NULL;
    @autoreleasepool {
        @synchronized([NSObject class]) {
            MVQueueEntry *e = MVQueueForAQ(inAQ);
            origCb = e ? e->cb : NULL;
            NSInteger idx;
            if (e) {
                idx = (NSInteger)(e - g_mvQueues);
            } else {
                // 未登记过的队列：用带独立偏移的兜底槽（千万不能和别的队列共享偏移）
                g_mvFallback.rate = 0;
                e = &g_mvFallback;
                idx = MV_SLOT_FALLBACK;
            }

            if (g_mvArmed && g_mvFeed.length && inBuffer && inBuffer->mAudioData) {
                // 超时保护：用户一直不松手/异常情况下别永久劫持麦克风
                if (g_mvArmAt > 0 && [[NSDate date] timeIntervalSince1970] - g_mvArmAt > kMVArmTimeout) {
                    g_mvArmed = NO;
                    g_mvFeed = nil;
                    for (int i = 0; i <= MV_MAX_QUEUES; i++) { g_mvQRes[i] = nil; g_mvQResRate[i] = 0; }
                    for (NSInteger i = 0; i < g_mvQueueCount; i++) g_mvQueues[i].off = 0;
                    g_mvFallback.off = 0;
                    MVLogS(@"[rec] 装填超时（%.0fs）自动取消", kMVArmTimeout);
                } else {
                    g_mvCbSeq++;

                    // 按【本队列】的采样率准备数据；每队列各自一份副本、各自从 0 开始
                    double rate = (e->rate > 0) ? e->rate : MV_WECHAT_SR;
                    if (!g_mvQRes[idx].length || g_mvQResRate[idx] != rate) {
                        NSData *r = MVResampleS16(g_mvFeed, MV_WECHAT_SR, rate);
                        if (r.length) {
                            g_mvQRes[idx] = r;
                            g_mvQResRate[idx] = rate;
                            e->off = 0;              // 只有"本队列首次准备"才归零
                        }
                    }
                    NSData *src = g_mvQRes[idx].length ? g_mvQRes[idx] : (NSData*)g_mvFeed;

                    if (!e->loggedStart) {
                        e->loggedStart = YES;
                        // 每次装填每队列只落一次盘：日志里从此能确认「替换真的发生了」
                        MVLog(@"[rec] ▶ 开始替换录音数据（第 %ld 个队列 %.0fHz，主档 %lu 字节）",
                              (long)idx, rate, (unsigned long)g_mvFeed.length);
                    }

                    UInt32 bufSz = inBuffer->mAudioDataByteSize;
                    if (!bufSz) bufSz = inBuffer->mAudioDataBytesCapacity;
                    NSUInteger total = src.length;
                    if (bufSz && e->off < total) {
                        NSUInteger take = MIN((NSUInteger)bufSz, total - e->off);
                        memcpy(inBuffer->mAudioData, (const char*)src.bytes + e->off, take);
                        if (take < bufSz)
                            memset((char*)inBuffer->mAudioData + take, 0, bufSz - take);
                        e->off += take;
                        if (e->off >= total) {
                            MVLogS(@"[rec] OK 队列#%ld TTS 已全部进入录音管线（%lu 字节）",
                                   (long)idx, (unsigned long)total);
                            MVLog(@"[rec] ✅ 队列#%ld TTS 已全部进入录音管线（共 %lu 字节）",
                                  (long)idx, (unsigned long)total);
                            g_mvArmAt = 0;   // 已喂完，不必再超时取消
                        }
                    } else if (bufSz) {
                        memset(inBuffer->mAudioData, 0, bufSz);   // 尾部静音
                    }
                }
            }
        }
    }
    // 无论是否替换，都要调微信原回调（微信以为这是自己录的音）
    if (origCb)
        origCb(inUserData, inAQ, inBuffer, inStartTime, inNumberPacketDescriptions, inPacketDescs);
}

#pragma mark - 补丁

// 清空一次装填的全部喂入状态（必须在 @synchronized([NSObject class]) 内调用）
static void MVResetFeedStateLocked(void) {
    for (int i = 0; i <= MV_MAX_QUEUES; i++) { g_mvQRes[i] = nil; g_mvQResRate[i] = 0; }
    for (NSInteger i = 0; i < g_mvQueueCount; i++) {
        g_mvQueues[i].off = 0;
        g_mvQueues[i].loggedStart = NO;
    }
    g_mvFallback.off = 0;
    g_mvFallback.loggedStart = NO;
    g_mvCbSeq = 0;
}

// 登记一个新创建的录音输入队列（线程安全；与实时回调共用一把锁）。
// aq 允许为 NULL：表示经由拿不到队列句柄的入口创建（见 dispatch 入口），作回退匹配的占位项。
static void MVRegisterQueue(AudioQueueRef aq, AudioQueueInputCallback cb,
                            const AudioStreamBasicDescription *fmt) {
    if (!cb) return;
    double rate = fmt ? fmt->mSampleRate : 0;
    UInt32  ch  = fmt ? fmt->mChannelsPerFrame : 0;
    @synchronized([NSObject class]) {
        for (NSInteger i = 0; i < g_mvQueueCount; i++) {
            if (g_mvQueues[i].aq == aq) {   // 同一队列重复创建（罕见）只刷新登记
                g_mvQueues[i].cb = cb; g_mvQueues[i].rate = rate; g_mvQueues[i].ch = ch;
                g_mvQueues[i].off = 0; g_mvQueues[i].loggedStart = NO;
                g_mvQRes[i] = nil; g_mvQResRate[i] = 0;
                return;
            }
        }
        NSInteger slot;
        if (g_mvQueueCount < MV_MAX_QUEUES) {
            slot = g_mvQueueCount++;
        } else {
            slot = MV_MAX_QUEUES - 1;       // 满了覆盖最后一个（实际场景远到不了 8 个）
            MVLog(@"[rec] 队列表已满，覆盖旧登记");
        }
        g_mvQueues[slot].aq = aq; g_mvQueues[slot].cb = cb;
        g_mvQueues[slot].rate = rate; g_mvQueues[slot].ch = ch;
        g_mvQueues[slot].off = 0; g_mvQueues[slot].loggedStart = NO;
        g_mvQRes[slot] = nil; g_mvQResRate[slot] = 0;
    }
    MVLog(@"[rec] 已接管录音队列（第 %ld 个）@%.0fHz %uch", g_mvQueueCount, rate, ch);
}

static void MVMakePipelineRateKnown(const AudioStreamBasicDescription *fmt) {
    if (!fmt) return;
    g_mvPipeRate = fmt->mSampleRate;
    g_mvPipeCh   = fmt->mChannelsPerFrame;
    if (!g_mvFmtLogged) {
        g_mvFmtLogged = YES;
        char fcode[5] = { (char)((fmt->mFormatID >> 24) & 0xFF),
                          (char)((fmt->mFormatID >> 16) & 0xFF),
                          (char)((fmt->mFormatID >> 8)  & 0xFF),
                          (char)( fmt->mFormatID        & 0xFF), 0 };
        MVLog(@"[rec] 录音管线格式：%.0fHz %uch fmt=%s bits=%u bytes/pkt=%u",
              fmt->mSampleRate, (unsigned)fmt->mChannelsPerFrame, fcode,
              (unsigned)fmt->mBitsPerChannel, (unsigned)fmt->mBytesPerPacket);
    }
}

static OSStatus MV_AudioQueueNewInput(const AudioStreamBasicDescription *inFormat,
                                      AudioQueueInputCallback inCallbackProc,
                                      void *inUserData, CFRunLoopRef inCFRunLoop,
                                      CFStringRef inCFRunLoopMode,
                                      UInt32 inFlags, AudioQueueRef *outAQ) {
    if (inCallbackProc && inUserData && outAQ) {
        MVMakePipelineRateKnown(inFormat);
        OSStatus st = g_mvOrigAQNewInput(inFormat, MV_AQInputTrampoline, inUserData,
                                         inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
        if (st == noErr) MVRegisterQueue(*outAQ, inCallbackProc, inFormat);
        return st;
    }
    return g_mvOrigAQNewInput(inFormat, inCallbackProc, inUserData,
                              inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
}

// iOS 10+ 的新入口（微信多数版本仍走老的 AudioQueueNewInput，两个都挂更保险）。
// 这个入口声明里拿不到 AudioQueueRef，没法精确按队列绑定 —— 用 aq=NULL 作占位键登记，
// trampoline 里精确匹配失败时回退到占位项（见 MVQueueForAQ）。
static OSStatus MV_AudioQueueNewInputWithDispatchQueue(AudioQueueRef *outAQ,
                                                       const AudioStreamBasicDescription *inFormat,
                                                       UInt32 inFlags,
                                                       dispatch_queue_t inCallbackQueue,
                                                       AudioQueueInputCallback inCallbackProc) {
    if (inCallbackProc && inFormat && outAQ) {
        MVMakePipelineRateKnown(inFormat);
        OSStatus st = g_mvOrigAQNewInputDisp(outAQ, inFormat, inFlags, inCallbackQueue, MV_AQInputTrampoline);
        if (st == noErr) MVRegisterQueue(NULL, inCallbackProc, inFormat);
        return st;
    }
    return g_mvOrigAQNewInputDisp(outAQ, inFormat, inFlags, inCallbackQueue, inCallbackProc);
}

#pragma mark - 对外

@implementation MyVoiceRecorder

+ (instancetype)shared {
    static id s; static dispatch_once_t t; dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            void *sym = (void*)AudioQueueNewInput;
            if (sym) {
                MSHookFunction(sym, (void*)MV_AudioQueueNewInput, (void**)&g_mvOrigAQNewInput);
                MVLog(@"[rec] AudioQueueNewInput hooked = %s", g_mvOrigAQNewInput ? "ok" : "FAIL");
            }
            void *sym2 = (void*)AudioQueueNewInputWithDispatchQueue;
            if (sym2) {
                MSHookFunction(sym2, (void*)MV_AudioQueueNewInputWithDispatchQueue,
                               (void**)&g_mvOrigAQNewInputDisp);
                MVLog(@"[rec] AudioQueueNewInputWithDispatchQueue hooked = %s",
                      g_mvOrigAQNewInputDisp ? "ok" : "FAIL");
            }
            g_mvHooked = YES;
        } @catch (NSException *e) {
            MVLog(@"[rec] 安装失败：%@", e.reason);
        }
    });
}

+ (NSUInteger)feedPCM:(NSData*)pcm srcRate:(double)srcRate {
    if (pcm.length < 320) {                 // 小于 10ms@16k 视为无效
        MVLog(@"[rec] 装填失败：PCM 太短（%lu 字节）", (unsigned long)pcm.length);
        return 0;
    }
    if (!g_mvHooked) [self install];

    // 主档统一 16kHz；具体由哪个录音队列消费、其采样率多少，回调发生时才知道，
    // 届时在 trampoline 里按队列采样率做一次性重采样（见 MV_AQInputTrampoline）。
    double dstRate = MV_WECHAT_SR;
    NSData *feed = MVResampleS16(pcm, srcRate > 0 ? srcRate : dstRate, dstRate);
    if (!feed.length) {
        MVLog(@"[rec] 装填失败：重采样无输出");
        return 0;
    }

    @synchronized([NSObject class]) {
        g_mvFeed  = feed;
        g_mvArmed = YES;
        g_mvArmAt = [[NSDate date] timeIntervalSince1970];
        MVResetFeedStateLocked();          // 每队列偏移/重采样副本全部作废，各自从 0 开始
    }
    NSUInteger ms = feed.length * 1000 / (NSUInteger)(dstRate * 2);
    MVLog(@"[rec] 装填主档 %lu 字节 ≈ %lums @16kHz（原 %.0fHz / %lu 字节）— 等待发送",
          (unsigned long)feed.length, (unsigned long)ms, srcRate, (unsigned long)pcm.length);
    return ms;
}

+ (void)cancelFeed {
    @synchronized([NSObject class]) {
        g_mvArmed = NO;
        g_mvFeed  = nil;
        g_mvArmAt = 0;
        MVResetFeedStateLocked();
    }
    MVLog(@"[rec] 已取消装填");
}

+ (BOOL)isArmed {
    BOOL v = NO;
    @synchronized([NSObject class]) { v = g_mvArmed; }
    return v;
}

+ (NSUInteger)fedBytes {
    NSUInteger v = 0;
    @synchronized([NSObject class]) {
        for (NSInteger i = 0; i < g_mvQueueCount; i++)
            if (g_mvQueues[i].off > v) v = g_mvQueues[i].off;
        if (g_mvFallback.off > v) v = g_mvFallback.off;
    }
    return v;
}

+ (NSUInteger)totalBytes {
    NSUInteger v = 0;
    @synchronized([NSObject class]) {
        for (int i = 0; i <= MV_MAX_QUEUES; i++)
            if (g_mvQRes[i].length > v) v = g_mvQRes[i].length;
        if (!v) v = g_mvFeed.length;
    }
    return v;
}

+ (double)pipelineRate {
    double v = 0;
    @synchronized([NSObject class]) { v = g_mvPipeRate; }
    return v;
}

+ (NSString*)diag {
    NSMutableString *s = [NSMutableString string];
    @synchronized([NSObject class]) {
        [s appendFormat:@"AudioQueue hook：%@\n", g_mvHooked ? @"已安装 ✅" : @"未安装 ❌"];
        [s appendFormat:@"已接管录音队列：%ld 个\n", g_mvQueueCount];
        for (NSInteger i = 0; i < g_mvQueueCount; i++)
            [s appendFormat:@"  · 队列#%ld @%.0fHz %uch 已喂 %lu 字节%@\n", i, g_mvQueues[i].rate,
                g_mvQueues[i].ch, (unsigned long)g_mvQueues[i].off,
                g_mvQueues[i].aq ? @"" : @"（入口句柄未知，按回退匹配）"];
        [s appendFormat:@"待发送装填：%@（%lu/%lu 字节）\n",
            g_mvArmed ? @"就绪，等待发送" : @"无",
            (unsigned long)[self fedBytes],
            (unsigned long)[self totalBytes]];
    }
    [s appendFormat:@"日志文件：%@", MVLogFilePath() ?: @"(不可写)"];
    return s;
}

@end
