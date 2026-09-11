#import <Foundation/Foundation.h>

// 统一 TTS 引擎接口。产出 16kHz / 单声道 / S16 PCM，供微信录音管线消费。
@protocol MyVoiceEngine <NSObject>
- (void)synthesizeText:(NSString*)text
               voiceID:(NSString*)voiceID
            completion:(void(^)(NSData* pcm, NSError* err))completion;
@end

@interface MyVoiceEngine : NSObject
// 默认引擎：优先 AVSpeech 系统离线中文（真语音），其次 Flite，最后 Sine 占位。
+ (id<MyVoiceEngine>)defaultEngine;
// AVS 失败时的占位音兜底（16kHz 单声道 S16 正弦）。
+ (NSData*)placeholderPCM:(NSString*)text;
// 用系统 AVSpeechSynthesizer 播放预览（自然音色，仅试听，不直接产出 PCM）。
+ (void)previewText:(NSString*)text voiceID:(NSString*)voiceID;
// 系统可用音色列表（用于面板选择）。
+ (NSArray<NSString*>*)availableVoiceIDs;
// 采样率（PCM 消费端据此喂数据）。
+ (double)sampleRate;
@end
