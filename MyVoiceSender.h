#import <Foundation/Foundation.h>

// 负责把合成出的 PCM → SILK 编码 → 直发微信语音消息。
// 绕过 AudioQueue（微信 8.0.76 录音链路已不走 AudioQueue，旧注入方案无声）。
@interface MyVoiceSender : NSObject
+ (instancetype)shared;
// 触发一次合成语音发送：text 合成 PCM → SILK → 调微信内部 sendVoiceToWeChat:toUsr:
- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID;
@end
