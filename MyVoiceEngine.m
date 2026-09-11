#import "MyVoiceEngine.h"
#import <AVFoundation/AVFoundation.h>

// 内置 Sine 占位引擎：无外部依赖，必定可编译、可走通"合成→发送"整条管线。
// 真实离线语音请启用 Flite（见 MyVoiceFlite.m + flite/vendor.sh）。
@interface MVSineFallbackEngine : NSObject <MyVoiceEngine>
@end
@implementation MVSineFallbackEngine
- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    // 按字数估算时长：约 4 字/秒，最短 1s 最长 15s。生成 16kHz 单声道 S16 正弦。
    NSUInteger secs = MIN(15, MAX(1, text.length / 4 + 1));
    double sr = [MyVoiceEngine sampleRate];
    NSUInteger n = (NSUInteger)(sr * secs);
    NSMutableData *d = [NSMutableData dataWithLength:n * 2];
    short *buf = (short*)d.mutableBytes;
    double f = 180.0; // 基频，模拟人声频段
    for (NSUInteger i = 0; i < n; i++) {
        double t = (double)i / sr;
        // 简单包络避免爆音
        double env = sin(M_PI * (double)i / (double)n);
        buf[i] = (short)(sin(2.0 * M_PI * f * t) * 9000.0 * env);
    }
    if (completion) completion(d, nil);
}
@end

@implementation MyVoiceEngine

+ (double)sampleRate { return 16000.0; }

+ (id<MyVoiceEngine>)defaultEngine {
#ifdef MV_HAS_FLITE
    return [[NSClassFromString(@"MyVoiceFliteEngine") alloc] init] ?: [[MVSineFallbackEngine alloc] init];
#else
    return [[MVSineFallbackEngine alloc] init];
#endif
}

+ (void)previewText:(NSString*)text voiceID:(NSString*)voiceID {
    if (!text.length) return;
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    if (voiceID.length) {
        AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
        if (v) u.voice = v;
    } else {
        u.voice = [AVSpeechSynthesisVoice voiceForLanguage:@"zh-CN"];
    }
    u.rate = AVSpeechUtteranceDefaultSpeechRate;
    u.preUtteranceDelay = 0.1;
    static AVSpeechSynthesizer *syn;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ syn = [[AVSpeechSynthesizer alloc] init]; });
    [syn speakUtterance:u];
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
