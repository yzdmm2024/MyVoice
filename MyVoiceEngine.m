#import "MyVoiceEngine.h"
#import "MyVoiceCommon.h"
#import "MyVoiceCloud.h"
#import <AVFoundation/AVFoundation.h>

// 内置 Sine 占位引擎：无外部依赖的兜底，保证 AVS 失败时管线仍能跑通。
@interface MVSineFallbackEngine : NSObject <MyVoiceEngine>
@end
@implementation MVSineFallbackEngine
- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    if (completion) completion([MyVoiceEngine placeholderPCM:text], nil);
}
@end

@implementation MyVoiceEngine

// 预览用合成器（抽成文件静态，便于 stopPreview 复用，避免多次 speak 叠加外放）
static AVSpeechSynthesizer *gMVSyn = nil;

+ (double)sampleRate { return MV_WECHAT_SR; }  // 24000，微信语音标准

// 占位音：按字数估算时长（约 4 字/秒，1s~15s），生成 16kHz 单声道 S16 正弦，带包络防爆音。
+ (NSData*)placeholderPCM:(NSString*)text {
    NSUInteger secs = MIN(15, MAX(1, (text.length ?: 1) / 4 + 1));
    double sr = [MyVoiceEngine sampleRate];
    NSUInteger n = (NSUInteger)(sr * secs);
    NSMutableData *d = [NSMutableData dataWithLength:n * 2];
    short *buf = (short*)d.mutableBytes;
    double f = 180.0;
    for (NSUInteger i = 0; i < n; i++) {
        double t = (double)i / sr;
        double env = sin(M_PI * (double)i / (double)n);
        buf[i] = (short)(sin(2.0 * M_PI * f * t) * 9000.0 * env);
    }
    return d;
}

+ (id<MyVoiceEngine>)defaultEngine {
    // 优先级：AVSpeech 系统离线中文（真语音）> Flite > Sine 占位
    id avs = [[NSClassFromString(@"MyVoiceAVSEngine") alloc] init];
    if (avs) return avs;
#ifdef MV_HAS_FLITE
    id fl = [[NSClassFromString(@"MyVoiceFliteEngine") alloc] init];
    if (fl) return fl;
#endif
    return [[MVSineFallbackEngine alloc] init];
}

// ★ 2.4.2：把 16k 单声道 S16 PCM 包上 WAV 头，交给 AVAudioPlayer 外放试听
+ (NSData*)wavFromPCM:(NSData*)pcm sampleRate:(double)sr {
    NSMutableData *w = [NSMutableData dataWithCapacity:44 + pcm.length];
    uint8_t h[44] = {0};
    memcpy(h, "RIFF", 4);
    uint32_t sz = (uint32_t)(36 + pcm.length);           memcpy(h + 4, &sz, 4);
    memcpy(h + 8, "WAVEfmt ", 8);
    uint32_t fmtLen = 16;                                 memcpy(h + 16, &fmtLen, 4);
    uint16_t fmt = 1;                                     memcpy(h + 20, &fmt, 2);
    uint16_t ch = 1;                                      memcpy(h + 22, &ch, 2);
    uint32_t rate = (uint32_t)sr;                         memcpy(h + 24, &rate, 4);
    uint32_t byteRate = (uint32_t)(sr * 2);               memcpy(h + 28, &byteRate, 4);
    uint16_t align = 2;                                   memcpy(h + 32, &align, 2);
    uint16_t bits = 16;                                   memcpy(h + 34, &bits, 2);
    memcpy(h + 36, "data", 4);
    uint32_t dsz = (uint32_t)pcm.length;                  memcpy(h + 40, &dsz, 4);
    [w appendBytes:h length:44];
    [w appendData:pcm];
    return w;
}

+ (void)playWavData:(NSData*)wav {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mv_preview.wav"];
    [wav writeToFile:p atomically:YES];
    gMVPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:p] error:nil];
    gMVPlayer.volume = 1.0;
    [gMVPlayer play];
}

// 离线模式的系统朗读（engineMode=0 或云端不可用时的兜底）
+ (void)speakWithAVS:(NSString*)text voiceID:(NSString*)voiceID {
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    if (voiceID.length) {
        AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
        if (v) u.voice = v;
    } else {
        u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    }
    u.rate = AVSpeechUtteranceDefaultSpeechRate;
    u.preUtteranceDelay = 0.1;
    if (!gMVSyn) gMVSyn = [[AVSpeechSynthesizer alloc] init];
    [gMVSyn speakUtterance:u];
}

+ (void)previewText:(NSString*)text voiceID:(NSString*)voiceID {
    [self stopPreview];
    if (!text.length) return;
    // ★ 2.4.2：云端模式必须用【当前所选音色】真合成试听。
    //   旧版永远走 AVSpeech 系统音 —— 传入的 DashScope 音色 ID 它根本不认识，
    //   全部落到默认 zh-CN 系统音，用户听到「永远一个音色」。
    if (MVEngineMode() == 1 && MVAPIKey().length > 0) {
        BOOL cloudReady = (MVTTSProvider() == 1) || (MVCurrentVoiceID().length > 0);
        if (cloudReady) {
            MVLog(@"[preview] 云端试听 voice=%@ provider=%ld", voiceID, (long)MVTTSProvider());
            [[MyVoiceCloud shared] synthesizeText:text voiceID:voiceID
                                       completion:^(NSData *pcm, NSError *err){
                if (pcm.length) {
                    NSData *wav = [self wavFromPCM:pcm sampleRate:MV_WECHAT_SR];
                    MVOnMain(^{ [self playWavData:wav]; });
                } else {
                    MVLog(@"[preview] 云端试听失败 %@，回退系统音", err.localizedDescription);
                    MVOnMain(^{ [self speakWithAVS:text voiceID:voiceID]; });
                }
            }];
            return;
        }
    }
    [self speakWithAVS:text voiceID:voiceID];
}

// 预览播放器（云端试听外放）
static AVAudioPlayer *gMVPlayer = nil;

// 立即停止预览朗读（发送前调用，避免「预览外放」与「录音注入」串音造成重叠）
+ (void)stopPreview {
    if (gMVPlayer) {
        @try { [gMVPlayer stop]; } @catch (NSException *e) {}
        gMVPlayer = nil;
    }
    if (gMVSyn) {
        @try { [gMVSyn stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; } @catch (NSException *e) {}
    }
}

+ (NSArray<NSString*>*)availableVoiceIDs {
    NSMutableArray *ids = [NSMutableArray array];
    for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
        if ([v.language hasPrefix:@"zh"] || [v.language hasPrefix:@"en"]) {
            [ids addObject:v.identifier];
        }
    }
    return ids;
}

@end
