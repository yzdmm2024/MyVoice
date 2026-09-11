#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// 负责把合成出的 PCM 注入微信录音管线。
// 做法：MSHookFunction 拦截 AudioQueueNewInput，
// 微信录音时由系统分配 buffer，我们把 buffer 内容替换为合成 PCM（而非麦克风），
// 微信照常编码/发送——格式永远正确，且对微信版本只依赖"它用 AudioQueue 录音"这一点。
@interface MyVoiceSender : NSObject
+ (instancetype)shared;
- (void)installHook;   // 安装 AudioQueueNewInput 拦截（只装一次）
// 触发一次合成语音发送：text 合成 PCM 后，唤起微信录音并喂入。
- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID;
@end
