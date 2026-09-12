#import "MyVoiceRecorder.h"
#import "MyVoiceCommon.h"
#import <AudioToolbox/AudioToolbox.h>
#include <time.h>

// MSHookFunction（substrate / ellekit 都提供同名 C 符号）。
// 刻意不 include substrate.h：rootless 环境里那个头的路径在各家实现下不一致，
// 直接声明原型最省事，链接由 theos 的 tweak.mk 自动带上 -lsubstrate。
extern void MSHookFunction(void *symbol, void *hook, void **old);

// ============================================================
// 状态（全部读写都过 @synchronized([NSObject class])，与音频实时回调互斥）
// ============================================================

// 主档 PCM：固定 16kHz(MV_WECHAT_SR) 单声道 S16。
static NSData    *g_mvFeed    = nil;

// ★ 2.2.5：全局只保留【一份】重采样副本 + 【一份】喂入偏移 —— 单数据流。
//   2.2.4 的"每队列各自一份完整 TTS"会让两条输入流同时说同一句话 = 叠音/重音。
static NSData    *g_mvRes     = nil;   // 按绑定队列采样率重采样后的副本（nil = 用主档）
static double     g_mvResRate = 0;
static NSUInteger g_mvOff     = 0;     // 已喂字节（相对 g_mvRes / g_mvFeed）
static BOOL       g_mvArmed   = NO;    // 替换开关
static BOOL       g_mvFedDone = NO;    // TTS 是否已全部喂进管线
static NSTimeInterval g_mvArmAt = 0;   // 装填时刻（超时自动取消）

// ---- 队列登记：只用于「把原回调正确转发回去」 ----
// 微信进程里可能有多个 AudioQueue 录音队列（语音消息录音器、音色克隆的 AVAudioRecorder、
// VoIP…）。我们登记每一个，回调里按 inAQ 精确匹配拿回它自己的原回调再转发，
// 避免"把 A 队列的音频喂给 B 队列的回调"这种串台。
typedef struct {
    AudioQueueRef           aq;   // NULL = 该队列经由拿不到句柄的入口创建
    AudioQueueInputCallback cb;
    double                  rate;
    UInt32                  ch;
} MVQueueEntry;
#define MV_MAX_QUEUES 8
static MVQueueEntry g_mvQueues[MV_MAX_QUEUES];
static NSInteger    g_mvQueueCount = 0;
static AudioQueueInputCallback g_mvLastCb = NULL;   // 兜底转发（登记项匹配不到时用）

// ---- ★ 2.2.5 精确绑定：本次会话只替换【一个】队列 ----
// 旧版（2.2.0~2.2.4）只要 armed 就替换"所有"回调上来的队列。若同时存在两个输入队列，
// 同一段 TTS 会进两条流 → 用户听到的就是"两个声音/重音"。
// 现在：beginQueueBinding 之后【第一个新建的输入队列】才是本次的替换目标，其它队列原样不动。
static BOOL          g_mvBindWait   = NO;   // 等待"下一次登记即绑定"
static BOOL          g_mvBoundSet   = NO;   // 是否已绑定
static AudioQueueRef g_mvBoundAq    = NULL; // 绑定的队列句柄（NULL = 句柄未知）
static MVQueueEntry *g_mvBoundEntry = NULL; // 绑定的登记项（句柄未知时用它判等）
static AudioQueueInputCallback g_mvBoundCb = NULL;
static double        g_mvBoundRate  = 0;    // 绑定队列申报的采样率
static BOOL          g_mvRateLogged = NO;

static BOOL       g_mvHooked = NO;
static NSUInteger g_mvCbSeq  = 0;           // 回调序号（诊断）

// ---- ★ 2.2.6 回调节奏采样（诊断卡顿是否真由管线缺口造成）----
// 录音实时回调线程里只往数组里写数字（无 IO、无字符串拼接），文本拼装留给主线程
// 的 cadenceReport。判据：若回调间隔(ms)明显大于该块自身时长(字节/32 ms)，
// 说明录音管线中间出现缺口 = 真的会卡。
#define MV_CB_TRACE_MAX 96
static UInt32    g_mvCbSize[MV_CB_TRACE_MAX];
static UInt32    g_mvCbDtMs[MV_CB_TRACE_MAX];
static NSInteger g_mvCbTraceN = 0;
static uint64_t  g_mvLastNs   = 0;

static OSStatus (*g_mvOrigAQNewInput)(const AudioStreamBasicDescription*, AudioQueueInputCallback,
                                      void*, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef*) = NULL;
static OSStatus (*g_mvOrigAQNewInputDisp)(AudioQueueRef*, const AudioStreamBasicDescription*,
                                          UInt32, dispatch_queue_t,
                                          AudioQueueInputCallback) = NULL;

// 装填后多久没被消费就自动取消（避免一直劫持麦克风）
static const NSTimeInterval kMVArmTimeout = 120.0;
// beginQueueBinding 之后给"新队列登记"留的宽限期：超过它才允许"绑到首个回调队列"的兜底
static const NSTimeInterval kMVBindGrace  = 0.35;

static MVQueueEntry* MVQueueForAQ(AudioQueueRef aq) {
    MVQueueEntry *fallback = NULL;
    for (NSInteger i = 0; i < g_mvQueueCount; i++) {
        if (g_mvQueues[i].aq == aq) return &g_mvQueues[i];
        // aq==NULL 的占位项 = 经由拿不到队列句柄的入口创建，精确匹配失败时回退用它
        if (g_mvQueues[i].aq == NULL && !fallback) fallback = &g_mvQueues[i];
    }
    return fallback;
}

// 清空一次装填的全部喂入状态（必须在 @synchronized([NSObject class]) 内调用）
static void MVResetFeedStateLocked(void) {
    g_mvRes = nil; g_mvResRate = 0;
    g_mvOff = 0;
    g_mvFedDone = NO;
    g_mvCbSeq = 0;
    g_mvRateLogged = NO;
    g_mvCbTraceN = 0;
    g_mvLastNs = 0;
}

#pragma mark - 重采样（S16 单声道，线性插值）

// 真正的实现抽在 MyVoiceCommon.h（MVResampleS16Mono）——云端 wav 解码与这里共用同一条，
// 避免两处各写一份、行为不一致。这里只补一行日志。
static NSData* MVResampleS16(NSData *src, double srcRate, double dstRate) {
    NSData *out = MVResampleS16Mono(src, srcRate, dstRate);
    if (out && out != src && out.length != src.length) {
        MVLog(@"[rec] 重采样 %.0fHz → %.0fHz：%lu → %lu 样本",
              srcRate, dstRate,
              (unsigned long)(src.length / 2), (unsigned long)(out.length / 2));
    }
    return out;
}

#pragma mark - 音频回调 trampoline

// 策略（与参考实现 TTSFloat v29 v23 版完全一致，实测音质干净）：
//   每次回调把整块 buffer 用连续的 TTS 字节填满 —— 块内绝不留缝隙。
//   （曾经的「按实测速率节奏喂」会在 TTS 流与 buffer 流之间产生零填充间隙，
//     结果每 250ms 插一段静音 = 明显杂音，已废弃。）
//   TTS 耗尽后整块补零（静音），并置 fedDone 供发送方决定 StopRecord 时机。
static void MV_AQInputTrampoline(void *inUserData, AudioQueueRef inAQ,
                                 AudioQueueBufferRef inBuffer,
                                 const AudioTimeStamp *inStartTime,
                                 UInt32 inNumberPacketDescriptions,
                                 const AudioStreamPacketDescription *inPacketDescs) {
    AudioQueueInputCallback origCb = NULL;
    @autoreleasepool {
        @synchronized([NSObject class]) {
            MVQueueEntry *e = MVQueueForAQ(inAQ);
            origCb = (e && e->cb) ? e->cb : g_mvLastCb;

            // ---- 判定"这是不是本次要替换的那一个队列" ----
            BOOL isBound = NO;
            if (g_mvBoundSet) {
                isBound = (g_mvBoundAq != NULL) ? (inAQ == g_mvBoundAq)
                                                : (e != NULL && e == g_mvBoundEntry);
            } else if (g_mvArmed && g_mvArmAt > 0 &&
                       [[NSDate date] timeIntervalSince1970] - g_mvArmAt > kMVBindGrace) {
                // 兜底：启动后没有任何新队列登记（版本差异）→ 宽限期后绑到首个回调队列。
                // 留这 0.35s 宽限是为了先让"录音器队列的登记"发生，避免误绑到已有队列。
                g_mvBindWait  = NO;
                g_mvBoundSet  = YES;
                g_mvBoundAq   = inAQ;
                g_mvBoundEntry = e;
                g_mvBoundCb   = origCb;
                g_mvBoundRate = e ? e->rate : 0;
                isBound = YES;
                MVLog(@"[rec] 启动后未捕获到新队列登记，改绑首个回调队列（%.0fHz）",
                      g_mvBoundRate);
            }

            if (isBound && g_mvArmed && g_mvFeed.length && inBuffer && inBuffer->mAudioData) {
                // 超时保护：用户一直不松手/异常情况下别永久劫持麦克风
                if (g_mvArmAt > 0 && [[NSDate date] timeIntervalSince1970] - g_mvArmAt > kMVArmTimeout) {
                    g_mvArmed = NO;
                    g_mvFeed  = nil;
                    MVResetFeedStateLocked();
                    MVLogS(@"[rec] 装填超时（%.0fs）自动取消", kMVArmTimeout);
                } else {
                    g_mvCbSeq++;

                    // 按【绑定队列】申报的采样率准备数据（整场只做一次）
                    double rate = (g_mvBoundRate > 0) ? g_mvBoundRate : MV_WECHAT_SR;
                    if (!g_mvRes.length || g_mvResRate != rate) {
                        NSData *r = MVResampleS16(g_mvFeed, MV_WECHAT_SR, rate);
                        if (r.length) { g_mvRes = r; g_mvResRate = rate; g_mvOff = 0; }
                        if (!g_mvRateLogged) {
                            g_mvRateLogged = YES;
                            MVLog(@"[rec] ▶ 开始替换录音数据（队列 %.0fHz，主档 %lu 字节，喂入 %lu 字节）",
                                  rate, (unsigned long)g_mvFeed.length,
                                  (unsigned long)(g_mvRes.length ? g_mvRes.length : g_mvFeed.length));
                        }
                    }
                    NSData *src = g_mvRes.length ? g_mvRes : g_mvFeed;

                    UInt32 bufSz = inBuffer->mAudioDataByteSize;
                    if (!bufSz) bufSz = inBuffer->mAudioDataBytesCapacity;
                    NSUInteger total = src.length;
                    if (bufSz && g_mvOff < total) {
                        // 诊断采样：纯内存写（无 IO / 无字符串），不会影响实时性
                        uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
                        if (g_mvCbTraceN < MV_CB_TRACE_MAX) {
                            g_mvCbSize[g_mvCbTraceN] = bufSz;
                            g_mvCbDtMs[g_mvCbTraceN] =
                                (g_mvLastNs && nowNs > g_mvLastNs)
                                    ? (UInt32)((nowNs - g_mvLastNs) / 1000000ULL) : 0;
                            g_mvCbTraceN++;
                        }
                        g_mvLastNs = nowNs;

                        // 整块填满：块内不留间隙（杂音根因就是间隙）
                        NSUInteger take = MIN((NSUInteger)bufSz, total - g_mvOff);
                        memcpy(inBuffer->mAudioData, (const char*)src.bytes + g_mvOff, take);
                        if (take < bufSz)
                            memset((char*)inBuffer->mAudioData + take, 0, bufSz - take);
                        g_mvOff += take;
                        if (g_mvOff >= total) {
                            g_mvFedDone = YES;
                            g_mvArmAt   = 0;   // 已喂完，不必再超时取消
                            MVLogS(@"[rec] OK TTS 已全部进入录音管线（%lu 字节，%lu 次回调）",
                                   (unsigned long)total, (unsigned long)g_mvCbSeq);
                            MVLog(@"[rec] ✅ TTS 已全部进入录音管线（共 %lu 字节，%lu 次回调）",
                                  (unsigned long)total, (unsigned long)g_mvCbSeq);
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

#pragma mark - 队列登记

// 登记一个新创建的录音输入队列（线程安全；与实时回调共用一把锁）。
// aq 允许为 NULL：表示经由拿不到队列句柄的入口创建（见 dispatch 入口），作回退匹配的占位项。
static MVQueueEntry* MVRegisterQueue(AudioQueueRef aq, AudioQueueInputCallback cb,
                                     const AudioStreamBasicDescription *fmt) {
    if (!cb) return NULL;
    double rate = fmt ? fmt->mSampleRate : 0;
    UInt32  ch  = fmt ? fmt->mChannelsPerFrame : 0;
    MVQueueEntry *ret = NULL;
    BOOL newlyBound = NO;

    @synchronized([NSObject class]) {
        g_mvLastCb = cb;

        for (NSInteger i = 0; i < g_mvQueueCount; i++) {
            if (g_mvQueues[i].aq == aq) {   // 同一队列重复创建（罕见）只刷新登记
                g_mvQueues[i].cb = cb; g_mvQueues[i].rate = rate; g_mvQueues[i].ch = ch;
                ret = &g_mvQueues[i];
                break;
            }
        }
        if (!ret) {
            NSInteger slot;
            if (g_mvQueueCount < MV_MAX_QUEUES) {
                slot = g_mvQueueCount++;
            } else {
                slot = MV_MAX_QUEUES - 1;       // 满了覆盖最后一个（实际场景远到不了 8 个）
                MVLog(@"[rec] 队列表已满，覆盖旧登记");
            }
            g_mvQueues[slot].aq = aq; g_mvQueues[slot].cb = cb;
            g_mvQueues[slot].rate = rate; g_mvQueues[slot].ch = ch;
            ret = &g_mvQueues[slot];
        }

        // ★ 精确绑定：beginQueueBinding 之后第一个登记的队列 = 本次要替换的队列
        if (g_mvBindWait && !g_mvBoundSet) {
            g_mvBindWait   = NO;
            g_mvBoundSet   = YES;
            g_mvBoundAq    = aq;
            g_mvBoundEntry = ret;
            g_mvBoundCb    = cb;
            g_mvBoundRate  = rate;
            newlyBound     = YES;
        }
    }

    MVLog(@"[rec] 已登记录音队列（第 %ld 个）@%.0fHz %uch%@",
          (long)g_mvQueueCount, rate, ch, newlyBound ? @" ← 本次替换目标" : @"");
    return ret;
}

static void MVMakePipelineRateKnown(const AudioStreamBasicDescription *fmt) {
    if (!fmt) return;
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        char fcode[5] = { (char)((fmt->mFormatID >> 24) & 0xFF),
                          (char)((fmt->mFormatID >> 16) & 0xFF),
                          (char)((fmt->mFormatID >> 8)  & 0xFF),
                          (char)( fmt->mFormatID        & 0xFF), 0 };
        MVLog(@"[rec] 录音管线申请格式：%.0fHz %uch fmt=%s bits=%u bytes/pkt=%u",
              fmt->mSampleRate, (unsigned)fmt->mChannelsPerFrame, fcode,
              (unsigned)fmt->mBitsPerChannel, fmt->mBytesPerPacket);
    }
}

#pragma mark - 补丁

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

+ (void)beginQueueBinding {
    @synchronized([NSObject class]) {
        g_mvBindWait   = YES;
        g_mvBoundSet   = NO;
        g_mvBoundAq    = NULL;
        g_mvBoundEntry = NULL;
        g_mvBoundCb    = NULL;
        g_mvBoundRate  = 0;
    }
    MVLog(@"[rec] 已进入「等待新队列」状态：下一个新建的录音队列将被精确绑定");
}

+ (NSUInteger)feedPCM:(NSData*)pcm srcRate:(double)srcRate {
    if (pcm.length < 320) {                 // 小于 10ms@16k 视为无效
        MVLog(@"[rec] 装填失败：PCM 太短（%lu 字节）", (unsigned long)pcm.length);
        return 0;
    }
    if (!g_mvHooked) [self install];

    // 主档统一 16kHz；消费队列的采样率在"绑定"时才知道，届时做一次性重采样。
    double dstRate = MV_WECHAT_SR;
    NSData *feed = MVResampleS16(pcm, srcRate > 0 ? srcRate : dstRate, dstRate);
    if (!feed.length) {
        MVLog(@"[rec] 装填失败：重采样无输出");
        return 0;
    }

    @synchronized([NSObject class]) {
        g_mvFeed  = feed;
        g_mvArmed = YES;
        // 绑定状态随每次装填重置：必须由发送方在"调启动方法前"重新 beginQueueBinding
        g_mvBindWait   = NO;
        g_mvBoundSet   = NO;
        g_mvBoundAq    = NULL;
        g_mvBoundEntry = NULL;
        g_mvBoundCb    = NULL;
        g_mvBoundRate  = 0;
        g_mvArmAt = [[NSDate date] timeIntervalSince1970];
        MVResetFeedStateLocked();
    }
    NSUInteger ms = feed.length * 1000 / (NSUInteger)(dstRate * 2);
    MVLog(@"[rec] 装填主档 %lu 字节 ≈ %lums @16kHz（引擎输出 %.0fHz / %lu 字节）— 等待发送",
          (unsigned long)feed.length, (unsigned long)ms, srcRate, (unsigned long)pcm.length);
    // 诊断落盘（只保留最后一次）：把**真正喂进录音管线**的 16kHz PCM 存成 wav。
    // 目的：若还有"卡/变调"，可直接拖出来听 + 量，不必靠猜。
    // 位置在信号量之外、且不在音频回调线程上，开销可忽略。
    @try {
        NSString *lp = MVLogFilePath();
        NSString *dir = lp.length ? [lp stringByDeletingLastPathComponent]
                                  : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        NSData *wav = MVWav16kFromPCM(feed);
        if (wav) {
            NSString *dp = [dir stringByAppendingPathComponent:@"MyVoice_last.wav"];
            if ([wav writeToFile:dp atomically:NO])
                MVLog(@"[rec] 诊断 wav 已写出：%@（%.2fs / %lu 字节）",
                      dp, ms / 1000.0, (unsigned long)wav.length);
        }
    } @catch (NSException *e) { MVLog(@"[rec] 诊断 wav 写出异常 %@", e.reason); }

    return ms;
}

+ (void)cancelFeed {
    @synchronized([NSObject class]) {
        g_mvArmed = NO;
        g_mvFeed  = nil;
        g_mvArmAt = 0;
        g_mvBindWait = NO;
        MVResetFeedStateLocked();
    }
    MVLog(@"[rec] 已取消装填");
}

+ (void)resetAfterSend:(NSTimeInterval)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, delay) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized([NSObject class]) {
            if (!g_mvArmed) return;      // 已被新一轮装填接管 → 不要误清
            g_mvArmed  = NO;
            g_mvFeed   = nil;
            g_mvArmAt  = 0;
            g_mvBindWait   = NO;
            g_mvBoundSet   = NO;
            g_mvBoundAq    = NULL;
            g_mvBoundEntry = NULL;
            g_mvBoundCb    = NULL;
            g_mvBoundRate  = 0;
            MVResetFeedStateLocked();
        }
        MVLog(@"[rec] 发送收尾：已解除装填（后续录音不受影响）");
    });
}

+ (BOOL)isArmed {
    BOOL v = NO;
    @synchronized([NSObject class]) { v = g_mvArmed; }
    return v;
}

+ (NSUInteger)fedBytes {
    NSUInteger v = 0;
    @synchronized([NSObject class]) { v = g_mvOff; }
    return v;
}

+ (NSUInteger)totalBytes {
    NSUInteger v = 0;
    @synchronized([NSObject class]) { v = g_mvRes.length ? g_mvRes.length : g_mvFeed.length; }
    return v;
}

+ (BOOL)fedDone {
    BOOL v = NO;
    @synchronized([NSObject class]) { v = g_mvFedDone; }
    return v;
}

// 回调节奏报告（诊断用，在主线程调用；实时回调只写数字，不做字符串/IO）
+ (NSString*)cadenceReport {
    NSMutableString *s = [NSMutableString string];
    @synchronized([NSObject class]) {
        NSInteger n = g_mvCbTraceN;
        [s appendFormat:@"替换期回调 %ld 次 | 每块字节 [", (long)n];
        for (NSInteger i = 0; i < n && i < 20; i++) [s appendFormat:@"%u ", g_mvCbSize[i]];
        [s appendString:@"] | 间隔ms ["];
        for (NSInteger i = 0; i < n && i < 20; i++) [s appendFormat:@"%u ", g_mvCbDtMs[i]];
        [s appendString:@"]  （每块时长≈字节/32 ms；间隔明显大于块时长 = 管线中间有缺口）"];
    }
    return s;
}

+ (double)pipelineRate {
    double v = 0;
    @synchronized([NSObject class]) { v = g_mvBoundRate; }
    return v;
}

+ (NSString*)diag {
    NSMutableString *s = [NSMutableString string];
    @synchronized([NSObject class]) {
        [s appendFormat:@"AudioQueue hook：%@\n", g_mvHooked ? @"已安装 ✅" : @"未安装 ❌"];
        [s appendFormat:@"已登记录音队列：%ld 个\n", (long)g_mvQueueCount];
        for (NSInteger i = 0; i < g_mvQueueCount; i++)
            [s appendFormat:@"  · 队列#%ld @%.0fHz %uch%@\n", (long)i, g_mvQueues[i].rate,
                g_mvQueues[i].ch,
                (g_mvBoundSet && &g_mvQueues[i] == g_mvBoundEntry) ? @" ← 本次替换目标" :
                    (g_mvQueues[i].aq ? @"" : @"（入口句柄未知）")];
        [s appendFormat:@"本次绑定：%@（%.0fHz）\n",
            g_mvBoundSet ? (g_mvBoundAq ? @"已绑定句柄 ✅" : @"已绑定(句柄未知) ✅") : @"尚未绑定",
            g_mvBoundRate];
        [s appendFormat:@"待发送装填：%@（%lu/%lu 字节，喂完=%@）\n",
            g_mvArmed ? @"就绪，等待发送" : @"无",
            (unsigned long)g_mvOff, (unsigned long)[self totalBytes],
            g_mvFedDone ? @"是" : @"否"];
    }
    [s appendFormat:@"日志文件：%@", MVLogFilePath() ?: @"(不可写)"];
    return s;
}

@end
