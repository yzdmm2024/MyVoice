#import <Foundation/Foundation.h>
#import "MyVoiceEngine.h"

// 云端引擎：DashScope CosyVoice（北京地域，MAAS 业务空间）。
//  - 合成：SpeechSynthesizer 端点 → 返回音频 URL → 下载 wav → 解码为 24k S16 PCM
//  - 克隆：customization 端点（一次性，参考音频走 OSS 公网 URL）
@interface MyVoiceCloud : NSObject <MyVoiceEngine>
+ (instancetype)shared;

// 连通性自检：故意发一个"参数不完整"的请求，靠 HTTP 状态码判断鉴权是否通过。
// 不产生费用、不创建音色、无副作用。ok=YES 表示 Key 可用。
- (void)testAPIKeyWithCompletion:(void(^)(BOOL ok, NSString *message))completion;

// TTS（MyVoiceEngine 协议）：text + voiceID → 24k 单声道 S16 PCM
- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData* pcm, NSError* err))completion;

// 声音复刻：把一段参考音频（本地文件路径）上传 OSS → 调 customization → 回调 voice_id
- (void)cloneVoiceWithName:(NSString*)name
              referenceAudioPath:(NSString*)path
                      completion:(void(^)(NSString* voiceID, NSError* err))completion;

// 声音设计：只给一句文字描述（如"沉稳的中年男性播音员"）→ 调 customization 的
// voice_prompt 分支 → 回调 voice_id。不需要参考音频、不需要录音、不需要 OSS。
- (void)designVoiceWithName:(NSString*)name
                     prompt:(NSString*)prompt
                previewText:(NSString*)previewText
                 completion:(void(^)(NSString* voiceID, NSError* err))completion;
@end
