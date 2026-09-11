#import "MyVoiceEngine.h"
#import "MyVoiceCommon.h"
#import <AVFoundation/AVFoundation.h>

// 真·离线中文 TTS：直接吃 iOS 系统 AVSpeechSynthesizer（设备内置 zh-CN 语音，全程在端，
// 不联网、不塞模型权重），自己写浮点线性重采样到 16kHz 单声道 S16，喂给微信录音管线。
// 比 Flite 中文效果好得多，且零依赖。需要 iOS 13+ 的 writeUtterance:toBufferCallback:。
// 注意：刻意不碰 AVAudioConverter / AVAudioPCMBuffer 构造器——它们在新 SDK（iOS17.x）被
// 可用性门槛拦掉，自己重采样最稳、跨 SDK 不翻车。
@interface MyVoiceAVSEngine : NSObject <MyVoiceEngine>
@end

@implementation MyVoiceAVSEngine

// 浮点单声道线性重采样：src(rate=srcRate) -> dst(rate=dstRate)
+ (NSData*)resampleFloat:(const float*)src frames:(NSUInteger)nSrc srcRate:(double)srcRate dstRate:(double)dstRate {
    if (nSrc == 0) return nil;
    if (srcRate <= 0 || dstRate <= 0) return nil;
    double ratio = dstRate / srcRate;               // 如 16000/24000 = 2/3
    NSUInteger nDst = (NSUInteger)(nSrc * ratio);
    if (nDst == 0) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:nDst * sizeof(short)];
    short *od = (short*)out.mutableBytes;
    for (NSUInteger i = 0; i < nDst; i++) {
        double pos = (double)i / ratio;             // 源位置（浮点）
        NSUInteger idx = (NSUInteger)pos;
        double frac = pos - (double)idx;
        float a = src[idx];
        float b = (idx + 1 < nSrc) ? src[idx + 1] : src[idx];
        float v = a * (1.0f - (float)frac) + b * (float)frac;
        if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
        od[i] = (short)(v * 32767.0f);
    }
    return out;
}

- (void)synthesizeText:(NSString*)text
               voiceID:(NSString*)voiceID
            completion:(void(^)(NSData*, NSError*))completion {

    if (!text.length) {
        if (completion) completion(nil, [NSError errorWithDomain:@"MyVoiceAVS" code:-1
                                    userInfo:@{NSLocalizedDescriptionKey:@"文字为空"}]);
        return;
    }

    // writeUtterance 是同步离线渲染（回调在调用线程上逐个给 buffer，最后给 nil），
    // 丢到后台线程跑，避免阻塞调用方。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
            if (voiceID.length) {
                AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
                u.voice = v ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
            } else {
                u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
            }
            u.rate = AVSpeechUtteranceDefaultSpeechRate;
            u.preUtteranceDelay = 0.0;
            u.postUtteranceDelay = 0.0;

            AVSpeechSynthesizer *syn = [[AVSpeechSynthesizer alloc] init];

            NSMutableData *srcFloats = [NSMutableData data]; // 累积 float32 单声道样本
            __block double srcRate = 24000.0;
            __block NSUInteger totalFrames = 0;
            __block BOOL gotAny = NO;

            [syn writeUtterance:u toBufferCallback:^(AVAudioBuffer * _Nullable buffer){
                if (!buffer || ![buffer isKindOfClass:[AVAudioPCMBuffer class]]) return;
                AVAudioPCMBuffer *pcm = (AVAudioPCMBuffer*)buffer;
                UInt32 frames = pcm.frameLength;
                if (frames == 0) return;
                srcRate = pcm.format.sampleRate;
                gotAny = YES;
                if (pcm.format.commonFormat == AVAudioPCMFormatFloat32) {
                    const float *ch0 = pcm.floatChannelData[0];
                    [srcFloats appendBytes:ch0 length:(NSUInteger)frames * sizeof(float)];
                } else if (pcm.format.commonFormat == AVAudioPCMFormatInt16) {
                    const short *ch0 = pcm.int16ChannelData[0];
                    float tmp;
                    for (UInt32 i = 0; i < frames; i++) {
                        tmp = ch0[i] / 32768.0f;
                        [srcFloats appendBytes:&tmp length:sizeof(float)];
                    }
                }
                totalFrames += frames;
            }];

            if (!gotAny || totalFrames == 0) {
                if (completion) completion(nil, [NSError errorWithDomain:@"MyVoiceAVS" code:1
                                    userInfo:@{NSLocalizedDescriptionKey:@"AVS 无输出（设备可能缺 zh-CN 语音，请在 设置-辅助功能-语音内容 中下载）"}]);
                return;
            }

            double dstRate = [MyVoiceEngine sampleRate]; // 16000
            NSData *out = [MyVoiceAVSEngine resampleFloat:(const float*)srcFloats.bytes
                                                   frames:totalFrames
                                                 srcRate:srcRate
                                                 dstRate:dstRate];
            if (!out || out.length == 0) {
                if (completion) completion(nil, [NSError errorWithDomain:@"MyVoiceAVS" code:2
                                    userInfo:@{NSLocalizedDescriptionKey:@"重采样失败"}]);
                return;
            }
            MVLog(@"AVS 合成完成：src %.0fHz/%lu帧 → dst %.0fHz/%lu帧",
                  srcRate, (unsigned long)totalFrames, dstRate, (unsigned long)(out.length / 2));
            if (completion) completion(out, nil);
        }
    });
}

@end
