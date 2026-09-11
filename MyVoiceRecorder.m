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

static NSData   *g_mvFeed       = nil;   // 待喂 PCM（已是管线采样率）
static NSUInteger g_mvOff       = 0;     // 已喂字节
static BOOL      g_mvArmed      = NO;    // 替换开关
static NSTimeInterval g_mvArmAt = 0;     // 装填时刻（用于超时自动取消）

static double    g_mvPipeRate   = 0;     // AudioQueueNewInput 报出的采样率
static UInt32    g_mvPipeCh     = 0;     // 声道数
static BOOL      g_mvFmtLogged  = NO;
static NSUInteger g_mvCbSeq     = 0;     // 回调序号（诊断）

// 原始实现
static AudioQueueInputCallback g_mvOrigCb = NULL;
static OSStatus (*g_mvOrigAQNewInput)(const AudioStreamBasicDescription*, AudioQueueInputCallback,
                                      void*, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef*) = NULL;
static OSStatus (*g_mvOrigAQNewInputDisp)(const AudioStreamBasicDescription*, void*,
                                          AudioQueueInputCallback, dispatch_queue_t) = NULL;

static BOOL g_mvHooked = NO;

// 装填后多久没被消费就自动取消（避免一直劫持麦克风）
static const NSTimeInterval kMVArmTimeout = 120.0;

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
    @autoreleasepool {
        @synchronized([NSObject class]) {
            if (g_mvArmed && g_mvFeed.length && inBuffer && inBuffer->mAudioData) {
                // 超时保护：用户一直不松手/异常情况下别永久劫持麦克风
                if (g_mvArmAt > 0 && [[NSDate date] timeIntervalSince1970] - g_mvArmAt > kMVArmTimeout) {
                    g_mvArmed = NO;
                    g_mvFeed = nil;
                    MVLog(@"[rec] 装填超时（%.0fs）自动取消", kMVArmTimeout);
                } else {
                    g_mvCbSeq++;
                    UInt32 bufSz = inBuffer->mAudioDataByteSize;
                    if (!bufSz) bufSz = inBuffer->mAudioDataBytesCapacity;
                    NSUInteger total = g_mvFeed.length;
                    if (bufSz && g_mvOff < total) {
                        NSUInteger take = MIN((NSUInteger)bufSz, total - g_mvOff);
                        memcpy(inBuffer->mAudioData, (const char*)g_mvFeed.bytes + g_mvOff, take);
                        if (take < bufSz)
                            memset((char*)inBuffer->mAudioData + take, 0, bufSz - take);
                        g_mvOff += take;
                        if (g_mvCbSeq <= 3 || g_mvOff >= total)
                            MVLog(@"[rec] 喂入 #%lu %luB (off=%lu/%lu)",
                                  (unsigned long)g_mvCbSeq, (unsigned long)take,
                                  (unsigned long)g_mvOff, (unsigned long)total);
                        if (g_mvOff >= total) {
                            MVLog(@"[rec] ✅ TTS 数据已全部进入录音管线（共 %lu 字节，%lu 次回调）",
                                  (unsigned long)total, (unsigned long)g_mvCbSeq);
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
    if (g_mvOrigCb)
        g_mvOrigCb(inUserData, inAQ, inBuffer, inStartTime, inNumberPacketDescriptions, inPacketDescs);
}

#pragma mark - 补丁

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
    if (inCallbackProc && inUserData && !g_mvOrigCb) {
        MVMakePipelineRateKnown(inFormat);
        g_mvOrigCb = inCallbackProc;
        MVLog(@"[rec] 已接管 AudioQueueNewInput（录音回调将经过替换层）");
        return g_mvOrigAQNewInput(inFormat, MV_AQInputTrampoline, inUserData,
                                  inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
    }
    return g_mvOrigAQNewInput(inFormat, inCallbackProc, inUserData,
                              inCFRunLoop, inCFRunLoopMode, inFlags, outAQ);
}

// iOS 10+ 的新入口（微信多数版本仍走老的 AudioQueueNewInput，两个都挂更保险）
static OSStatus MV_AudioQueueNewInputWithDispatchQueue(const AudioStreamBasicDescription *inFormat,
                                                       void *inUserData,
                                                       AudioQueueInputCallback inCallbackProc,
                                                       dispatch_queue_t inCallbackQueue) {
    if (inCallbackProc && inUserData && !g_mvOrigCb) {
        MVMakePipelineRateKnown(inFormat);
        g_mvOrigCb = inCallbackProc;
        MVLog(@"[rec] 已接管 AudioQueueNewInputWithDispatchQueue");
        return g_mvOrigAQNewInputDisp(inFormat, inUserData, MV_AQInputTrampoline, inCallbackQueue);
    }
    return g_mvOrigAQNewInputDisp(inFormat, inUserData, inCallbackProc, inCallbackQueue);
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

    // 目标采样率：优先用实测到的管线采样率，没有就用 16000（微信实测值）
    double dstRate = g_mvPipeRate > 0 ? g_mvPipeRate : 16000.0;
    NSData *feed = MVResampleS16(pcm, srcRate > 0 ? srcRate : dstRate, dstRate);
    if (!feed.length) {
        MVLog(@"[rec] 装填失败：重采样无输出");
        return 0;
    }

    @synchronized([NSObject class]) {
        g_mvFeed  = feed;
        g_mvOff   = 0;
        g_mvArmed = YES;
        g_mvArmAt = [[NSDate date] timeIntervalSince1970];
        g_mvCbSeq = 0;
    }
    NSUInteger ms = feed.length * 1000 / (NSUInteger)(dstRate * 2);
    MVLog(@"[rec] 装填 %lu 字节 ≈ %lums @%.0fHz（原 %.0fHz / %lu 字节）— 等待用户按住说话",
          (unsigned long)feed.length, (unsigned long)ms, dstRate,
          srcRate, (unsigned long)pcm.length);
    return ms;
}

+ (void)cancelFeed {
    @synchronized([NSObject class]) {
        g_mvArmed = NO;
        g_mvFeed  = nil;
        g_mvOff   = 0;
        g_mvArmAt = 0;
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
    @synchronized([NSObject class]) { v = g_mvOff; }
    return v;
}

+ (NSUInteger)totalBytes {
    NSUInteger v = 0;
    @synchronized([NSObject class]) { v = g_mvFeed.length; }
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
        [s appendFormat:@"录音管线采样率：%@（0 = 还没录过音）\n",
            g_mvPipeRate > 0 ? [NSString stringWithFormat:@"%.0fHz", g_mvPipeRate] : @"未知"];
        [s appendFormat:@"原始回调已捕获：%@\n", g_mvOrigCb ? @"是 ✅" : @"否（按住说话一次即可）"];
        [s appendFormat:@"待发送装填：%@（%lu/%lu 字节）",
            g_mvArmed ? @"就绪，等待按住说话" : @"无",
            (unsigned long)g_mvOff, (unsigned long)g_mvFeed.length];
    }
    return s;
}

@end
