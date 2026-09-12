#import "MyVoiceEngine.h"
#import "MyVoiceCommon.h"
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

+ (void)previewText:(NSString*)text voiceID:(NSString*)voiceID {
    if (!text.length) return;
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

// 立即停止预览朗读（发送前调用，避免「预览外放」与「录音注入」串音造成重叠）
+ (void)stopPreview {
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
