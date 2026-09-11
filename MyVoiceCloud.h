#import <Foundation/Foundation.h>
#import "MyVoiceEngine.h"

// 云端引擎：DashScope CosyVoice（北京地域，MAAS 业务空间）。
//  - 合成：SpeechSynthesizer 端点 → 返回音频 URL → 下载 wav → 解码为 24k S16 PCM
//  - 克隆：customization 端点（一次性，参考音频走 OSS 公网 URL）
@interface MyVoiceCloud : NSObject <MyVoiceEngine>
+ (instancetype)shared;

// TTS（MyVoiceEngine 协议）：text + voiceID → 24k 单声道 S16 PCM
- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData* pcm, NSError* err))completion;

// 声音复刻：把一段参考音频（本地文件路径）上传 OSS → 调 customization → 回调 voice_id
- (void)cloneVoiceWithName:(NSString*)name
              referenceAudioPath:(NSString*)path
                      completion:(void(^)(NSString* voiceID, NSError* err))completion;
@end
