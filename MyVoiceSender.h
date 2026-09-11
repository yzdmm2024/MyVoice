#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// 负责把合成出的 PCM 注入微信录音管线。
// 做法：MSHookFunction 拦截 AudioQueueNewInput，微信录音时我们把 buffer 内容替换为合成 PCM
//       （而非麦克风）；同时 hook AudioSender 的 StartRecordFrom: 捕获会话身份。
// 微信照常 SILK 编码/上传/气泡——格式永远正确，对微信版本主要依赖"它用 AudioQueue 录音 + AudioSender 录音"这两点。
@interface MyVoiceSender : NSObject
+ (instancetype)shared;
- (void)installHook;   // 安装 AudioQueueNewInput 拦截 + StartRecordFrom 观察 hook（只装一次）
// 触发一次合成语音发送：text 合成 PCM 后，唤起微信真实录音会话并喂入。
- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID;

// 会话身份（VC 自动识别失败时的兜底来源）：来自 StartRecordFrom 捕获 + 持久化
+ (NSString*)capturedToUsr;       // 对方 wxid（聊天对象）
+ (NSString*)capturedFrom;        // 自己身份
+ (NSDictionary*)capturedUserInfo;// 录音会话 userData
+ (id)audioSenderInstance;        // 当前/新建 AudioSender 实例

// 类方法：操作全局录制状态（C 函数回调与收尾共用）
+ (void)cleanup;
@end
