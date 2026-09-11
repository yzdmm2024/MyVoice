#import <Foundation/Foundation.h>

// SILK 编码器封装：复用微信进程内已加载的 libsilk（dlsym），不自带体积庞大的编码器。
// 微信语音消息体就是 SILK，必须编码成 SILK 才能被对方播放。
@interface MyVoiceSILK : NSObject
+ (instancetype)shared;
// 把 24kHz 单声道 S16 PCM 编码成完整 SILK 数据（含 SILK 头）。返回 nil 表示本机无可用的 SILK 符号。
- (NSData*)encodePCM:(NSData*)pcm24k;
@end
