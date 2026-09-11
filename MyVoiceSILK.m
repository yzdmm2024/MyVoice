#import "MyVoiceSILK.h"
#import "MyVoiceCommon.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// SILK 编码（2.0.17 重做）
//
// 背景（frida 实测微信 8.0.75.33）：
//   · 微信进程里 **没有** 标准 SILK_SDK 导出符号 silk_Encode / silk_Encode_Init
//     （全模块导出扫过，只有 TPFFmpeg 的 ff_silk_*，那是解码表）→ 老方案必然返回 nil。
//   · 微信自己的编解码器是 ObjC 类 MJSilkCodec：
//       + encodeToSilkFromPCMData:     类方法，NSData(PCM) → NSData(SILK)   ★首选
//       + decodeToPCMFromSilkData:     类方法，反向（可用来做编码自检）
//       - initEncoderWithSampleRate:   实例方式：初始化
//       - encodeFromPCMData:           实例方式：逐块编码
//   · 时长换算：AudioUtil + calcSilkVoiceTime:
//
// 所以优先级：① MJSilkCodec 类方法 → ② MJSilkCodec 实例方式 → ③ 老 silk_Encode 兜底
// ============================================================

typedef struct silk_encoder mv_silk_encoder;  // opaque（老 SDK 兜底用）

// ---- 老标准 SILK_SDK（仅兜底，多数新版微信已无）----
typedef struct {
    int API_sampleRate, maxInternalSampleRate, packetSize, packetLossPercentage;
    int useInBandFEC, useDTX, complexity, bitRate;
} mv_silk_enc_ctrl;

static int (*mv_silk_Encode_Init)(mv_silk_encoder **) = NULL;
static int (*mv_silk_Encode)(mv_silk_encoder *, const mv_silk_enc_ctrl *,
                             const short *, int, unsigned char *, int *) = NULL;
static int (*mv_silk_Encode_destroy)(mv_silk_encoder *) = NULL;
static BOOL mv_legacy_resolved = NO;

@implementation MyVoiceSILK

+ (instancetype)shared {
    static id s; static dispatch_once_t t; dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

#pragma mark - 能力探测

// 微信自带编解码器是否可用（每次查都很快，类可能晚于 tweak 加载，不能只在 init 里判一次）
+ (BOOL)wechatCodecAvailable {
    return NSClassFromString(@"MJSilkCodec") != nil;
}

- (void)resolveLegacy {
    if (mv_legacy_resolved) return;
    mv_legacy_resolved = YES;
    mv_silk_Encode_Init = (int(*)(mv_silk_encoder**))dlsym(RTLD_DEFAULT, "silk_Encode_Init");
    mv_silk_Encode = (int(*)(mv_silk_encoder*,const mv_silk_enc_ctrl*,const short*,int,unsigned char*,int*))dlsym(RTLD_DEFAULT, "silk_Encode");
    mv_silk_Encode_destroy = (int(*)(mv_silk_encoder*))dlsym(RTLD_DEFAULT, "silk_Encode_destroy");
    if (mv_silk_Encode_Init || mv_silk_Encode)
        MVLog(@"[silk] 兜底：找到老 SILK_SDK 导出符号");
}

#pragma mark - 对外：编码

- (NSData*)encodePCM:(NSData*)pcm24k {
    if (pcm24k.length < 2) return nil;

    // ① 微信自带实例编码器 —— 唯一验证过时长正确的路径
    //    （微信自己的 SilkAudioRecorder 也走这条：initEncoderWithSampleRate: + encodeFromPCMData:）
    if ([MyVoiceSILK wechatCodecAvailable]) {
        NSData *silk = [self encodeWithWeChatInstance:pcm24k];
        if (silk.length) return silk;
    }

    // ② 老 SDK 兜底
    [self resolveLegacy];
    NSData *legacy = [self encodeWithLegacySDK:pcm24k];
    if (legacy.length) return legacy;

    MVLog(@"[silk] 全部编码通道都失败（MJSilkCodec 实例、老 silk_Encode 都不可用）");
    return nil;
}

// ★ 主通道：MJSilkCodec 实例方式（微信录音用的就是这条）
//   - initEncoderWithSampleRate: 实测 B24@0:8q16 → BOOL + long long
//   - encodeFromPCMData:        实测 @24@0:8@16 → 返回 SILK 的 NSData
//   产物头 4 字节应含 "#!SILK_V3"（实测为 03 23 21 53 49 4c 4b 5f 56 33 …，即 \x03#!SILK_V3）
- (NSData*)encodeWithWeChatInstance:(NSData*)pcm {
    Class codec = NSClassFromString(@"MJSilkCodec");
    if (!codec) return nil;
    SEL allocSel = NSSelectorFromString(@"alloc");
    SEL initSel  = NSSelectorFromString(@"init");
    SEL initEnc  = NSSelectorFromString(@"initEncoderWithSampleRate:");
    SEL encSel   = NSSelectorFromString(@"encodeFromPCMData:");
    SEL uninitSel= NSSelectorFromString(@"uninitEncoder");
    @try {
        id inst = ((id(*)(id,SEL))objc_msgSend)(codec, allocSel);
        inst = ((id(*)(id,SEL))objc_msgSend)(inst, initSel);
        if (!inst) { MVLog(@"[silk] MJSilkCodec alloc/init 失败"); return nil; }
        if ([inst respondsToSelector:initEnc]) {
            BOOL ok = ((BOOL(*)(id,SEL,long long))objc_msgSend)(inst, initEnc, (long long)MV_WECHAT_SR);
            MVLog(@"[silk] initEncoderWithSampleRate:%d → %@", (int)MV_WECHAT_SR, ok ? @"OK" : @"失败");
        } else {
            MVLog(@"[silk] MJSilkCodec 不响应 initEncoderWithSampleRate:");
            return nil;
        }
        if (![inst respondsToSelector:encSel]) { MVLog(@"[silk] 不响应 encodeFromPCMData:"); return nil; }
        id r = ((id(*)(id,SEL,id))objc_msgSend)(inst, encSel, pcm);
        if ([inst respondsToSelector:uninitSel]) ((void(*)(id,SEL))objc_msgSend)(inst, uninitSel);
        if (![r isKindOfClass:[NSData class]]) {
            MVLog(@"[silk] encodeFromPCMData: 返回非 NSData（%@）",
                  NSStringFromClass(object_getClass(r)));
            return nil;
        }
        NSData *out = r;
        MVLog(@"[silk] ✅ 微信实例编码器 %lu B PCM → %lu B SILK（头 %@）",
              (unsigned long)pcm.length, (unsigned long)out.length,
              [self headerHexOf:out]);
        return out;
    } @catch (NSException *e) {
        MVLog(@"[silk] 实例方式编码异常 %@", e.reason);
        return nil;
    }
}

- (NSString*)headerHexOf:(NSData*)d {
    const unsigned char *b = d.bytes;
    NSUInteger n = MIN((NSUInteger)8, d.length);
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02x ", b[i]];
    return s;
}

// 备用：微信类方法（实测产物微信自己算时长恒为 20，**不能用**，仅作最后兜底）
- (NSData*)encodeWithWeChatClassMethod:(NSData*)pcm {
    Class codec = NSClassFromString(@"MJSilkCodec");
    SEL sel = NSSelectorFromString(@"encodeToSilkFromPCMData:");
    if (!codec || ![codec respondsToSelector:sel]) return nil;
    NSData *out = nil;
    @try { out = ((id(*)(id,SEL,id))objc_msgSend)(codec, sel, pcm); }
    @catch (NSException *e) { return nil; }
    if (![out isKindOfClass:[NSData class]]) return nil;
    MVLog(@"[silk] ⚠️ 走了类方法编码（时长可能不准）%lu B → %lu B",
          (unsigned long)pcm.length, (unsigned long)out.length);
    return out;
}

// ③ 老 SDK
- (NSData*)encodeWithLegacySDK:(NSData*)pcm {
    if (!mv_silk_Encode_Init || !mv_silk_Encode) return nil;
    mv_silk_encoder *enc = NULL;
    if (mv_silk_Encode_Init(&enc) != 0 || !enc) return nil;

    mv_silk_enc_ctrl ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.API_sampleRate = (int)MV_WECHAT_SR;
    ctrl.maxInternalSampleRate = (int)MV_WECHAT_SR;
    ctrl.packetSize = 480;      // 20ms @ 24k
    ctrl.complexity = 10;

    const short *samples = (const short*)pcm.bytes;
    int nTotal = (int)(pcm.length / 2);
    NSMutableData *out = [NSMutableData dataWithCapacity:pcm.length / 2];
    unsigned char payload[1024];
    int offset = 0;
    while (offset < nTotal) {
        int nIn = MIN(ctrl.packetSize, nTotal - offset);
        int nBytes = 0;
        if (mv_silk_Encode(enc, &ctrl, samples + offset, nIn, payload, &nBytes) != 0 || nBytes <= 0) break;
        [out appendBytes:payload length:nBytes];
        offset += nIn;
    }
    if (mv_silk_Encode_destroy && enc) mv_silk_Encode_destroy(enc);
    if (!out.length) return nil;
    MVLog(@"[silk] ✅ 老 SDK 编码 %lu bytes → %lu bytes", (unsigned long)pcm.length, (unsigned long)out.length);
    return out;
}

#pragma mark - 自检：SILK → PCM 反向验证

- (NSUInteger)pcmLengthFromSilk:(NSData*)silk {
    Class codec = NSClassFromString(@"MJSilkCodec");
    SEL sel = NSSelectorFromString(@"decodeToPCMFromSilkData:");
    if (!codec || ![codec respondsToSelector:sel] || !silk.length) return 0;
    @try {
        id r = ((id(*)(id,SEL,id))objc_msgSend)(codec, sel, silk);
        if ([r isKindOfClass:[NSData class]]) return ((NSData*)r).length;
    } @catch (NSException *e) { MVLog(@"[silk] 解码自检异常 %@", e.reason); }
    return 0;
}

#pragma mark - 时长（微信按 SILK 内容算时长，用于气泡上显示的秒数）

- (NSInteger)durationMsForSilk:(NSData*)silk {
    Class au = NSClassFromString(@"AudioUtil");
    SEL sel = NSSelectorFromString(@"calcSilkVoiceTime:");
    // 实测编码 I24@0:8@16 → 返回 unsigned int，单位是**毫秒**（1s→1000 / 2s→2000 / 3s→3000）
    if (au && [au respondsToSelector:sel] && silk.length) {
        @try {
            unsigned int ms = ((unsigned int(*)(id,SEL,id))objc_msgSend)(au, sel, silk);
            if (ms > 0) {
                MVLog(@"[silk] AudioUtil 时长 = %u ms", ms);
                return (NSInteger)ms;
            }
        } @catch (NSException *e) {}
    }
    return 0;
}

@end
