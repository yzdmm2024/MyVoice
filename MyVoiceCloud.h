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

// TTS（MyVoiceEngine 协议）：text + voiceID → 16k 单声道 S16 PCM
// ★ 2.2.7：本方法自带【结果缓存】（key = 服务商|模型|音色|语气|语速|文字）。
//   命中缓存时**零网络请求**直接回调 —— 这是消除「点发送后还要等合成」的关键。
- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData* pcm, NSError* err))completion;

// ★ 2.2.7 后台预合成：只把结果填进缓存，不发送、不发声。
//   面板里文字变化后调用它，用户点「发送」时就能命中缓存（合成耗时 0）。
//   已缓存 / 离线引擎 / 没配 Key 时直接返回，绝不打扰用户。
- (void)prewarmText:(NSString*)text voiceID:(NSString*)voiceID;

// ★ 2.2.7 连接预热：提前建好 DNS+TLS（实测首次合成 0.89s 里约 0.3~0.4s 花在握手上）。
//   幂等：默认 5 分钟内只暖一次。打开面板时调一次即可。
- (void)prewarmConnection;

// 清空合成缓存（换 Key / 换音色后可调）
+ (void)clearSynthesisCache;

// ★ 2.8.7：缓存统计（count 条 / bytes 字节），给面板「缓存管理」用
+ (NSDictionary*)cacheStats;

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
