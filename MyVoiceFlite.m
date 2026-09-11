#ifdef MV_HAS_FLITE
#import "MyVoiceEngine.h"
#import <AVFoundation/AVFoundation.h>
#include "flite.h"

// Flite 真实离线 TTS：直接产出 PCM，无需联网、不上传任何内容。
@interface MyVoiceFliteEngine : NSObject <MyVoiceEngine>
@end

@implementation MyVoiceFliteEngine

static BOOL fliteReady = NO;
static cst_voice *kal_voice = NULL;

- (instancetype)init {
    self = [super init];
    if (self) {
        if (!fliteReady) {
            @synchronized([MyVoiceFliteEngine class]) {
                if (!fliteReady) {
                    flite_init();
                    // 仅注册一个英文音色；中文需自行加入中文 voice 资源（见 README）。
                    kal_voice = register_cmu_us_kal(NULL);
                    fliteReady = YES;
                }
            }
        }
    }
    return self;
}

- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    if (!text.length) { if (completion) completion(nil, [NSError errorWithDomain:@"MyVoice" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"空文本"}]); return; }

    cst_voice *v = kal_voice;
    if (!v) { if (completion) completion(nil, [NSError errorWithDomain:@"MyVoice" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"Flite 音色未就绪"}]); return; }

    cst_wave *w = flite_text_to_wave((char*)text.UTF8String, v);
    if (!w) { if (completion) completion(nil, [NSError errorWithDomain:@"MyVoice" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"合成失败"}]); return; }

    // cst_wave: w->samples 为 short*，采样率 w->sample_rate，单声道。
    int sr = w->sample_rate;
    int nsamp = w->num_samples;
    short *src = w->samples;

    double target = [MyVoiceEngine sampleRate]; // 16000
    NSMutableData *out = [NSMutableData dataWithCapacity:nsamp * 2];
    if (sr == (int)target) {
        [out appendBytes:src length:nsamp * 2];
    } else {
        // 简单线性重采样到 16kHz
        double ratio = (double)target / (double)sr;
        int outN = (int)(nsamp * ratio);
        for (int i = 0; i < outN; i++) {
            int idx = (int)(i / ratio);
            if (idx >= nsamp) idx = nsamp - 1;
            short s = src[idx];
            [out appendBytes:&s length:2];
        }
    }
    delete_wave(w);
    if (completion) completion(out, nil);
}

@end
#endif
