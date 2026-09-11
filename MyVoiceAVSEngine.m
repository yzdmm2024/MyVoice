#import "MyVoiceEngine.h"
#import <AVFoundation/AVFoundation.h>

// 真·离线中文 TTS：直接吃 iOS 系统 AVSpeechSynthesizer（设备内置 zh-CN 语音，全程在端，
// 不联网、不塞模型权重），经 AVAudioConverter 降采样到 16kHz 单声道 S16，喂给微信录音管线。
// 比 Flite 中文效果好得多，且零依赖。需要 iOS 13+ 的 writeUtterance:toBufferCallback:。
@implementation MyVoiceAVSEngine

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
            __block AVAudioFormat *srcFmt = nil;
            __block double srcRate = 24000.0;
            __block NSUInteger totalFrames = 0;
            __block BOOL gotAny = NO;

            [syn writeUtterance:u toBufferCallback:^(AVAudioBuffer * _Nullable buffer){
                if (!buffer || ![buffer isKindOfClass:[AVAudioPCMBuffer class]]) return;
                AVAudioPCMBuffer *pcm = (AVAudioPCMBuffer*)buffer;
                UInt32 frames = pcm.frameLength;
                if (frames == 0) return;
                if (!srcFmt) srcFmt = pcm.format;
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
                                    userInfo:@{NSLocalizedDescriptionKey:@"AVS 无输出（设备可能缺 zh-CN 语音，请在系统设置-辅助功能-语音内容中下载）"}]);
                return;
            }

            // 拼成整段 float 源 buffer，再一次性降采样到 16k S16
            AVAudioFormat *sf = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                sampleRate:srcRate
                                                                channels:1
                                                             interleaved:NO];
            AVAudioPCMBuffer *srcBuf = [[AVAudioPCMBuffer alloc] initWithFormat:sf capacity:totalFrames];
            memcpy(srcBuf.floatChannelData[0], srcFloats.bytes, (NSUInteger)totalFrames * sizeof(float));
            srcBuf.frameLength = totalFrames;

            double dstRate = [MyVoiceEngine sampleRate]; // 16000
            AVAudioFormat *df = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                sampleRate:dstRate
                                                                channels:1
                                                             interleaved:NO];
            AVAudioConverter *conv = [[AVAudioConverter alloc] initFrom:sf to:df];
            if (!conv) {
                if (completion) completion(nil, [NSError errorWithDomain:@"MyVoiceAVS" code:2
                                    userInfo:@{NSLocalizedDescriptionKey:@"创建重采样器失败"}]);
                return;
            }
            NSUInteger outCap = (NSUInteger)(totalFrames * dstRate / srcRate) + 64;
            AVAudioPCMBuffer *dstBuf = [[AVAudioPCMBuffer alloc] initWithFormat:df capacity:outCap];
            NSError *cerr = nil;
            __block AVAudioPCMBuffer *sbuf = srcBuf;
            __block BOOL srcConsumed = NO;
            AVAudioConverterInputBlock pull = ^AVAudioBuffer*(AVAudioConverterInputStatus *status, AVAudioPacketCount *packetCount){
                if (srcConsumed) {
                    *status = AVAudioConverterInputStatusEndOfStream;
                    *packetCount = 0;
                    return nil;
                }
                srcConsumed = YES;
                *status = AVAudioConverterInputStatusHaveData;
                *packetCount = sbuf.frameLength;
                return sbuf;
            };
            BOOL ok = [conv convertToBuffer:dstBuf error:&cerr withInputFromBlock:pull];
            if (!ok || cerr) {
                if (completion) completion(nil, cerr ?: [NSError errorWithDomain:@"MyVoiceAVS" code:3
                                    userInfo:@{NSLocalizedDescriptionKey:@"重采样失败"}]);
                return;
            }
            UInt32 outFrames = dstBuf.frameLength;
            NSData *out = [NSData dataWithBytes:dstBuf.int16ChannelData[0] length:(NSUInteger)outFrames * sizeof(short)];
            MVLog(@"AVS 合成完成：src %.0fHz/%lu帧 → dst %.0fHz/%u帧", srcRate, (unsigned long)totalFrames, dstRate, outFrames);
            if (completion) completion(out, nil);
        }
    });
}

@end
