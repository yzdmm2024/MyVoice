#import <Foundation/Foundation.h>

// SILK 编解码封装（2.0.17：改用微信自带的 MJSilkCodec，不再依赖不存在的 silk_Encode 符号）
@interface MyVoiceSILK : NSObject
+ (instancetype)shared;

// 把 24kHz / 单声道 / S16 的 PCM 编码成微信语音用的 SILK 数据。nil = 全部通道失败。
- (NSData*)encodePCM:(NSData*)pcm24k;

// 自检：把 SILK 解回 PCM，返回 PCM 字节数（0 = 解码失败）。用于确认编码真的可用。
- (NSUInteger)pcmLengthFromSilk:(NSData*)silk;

// 由 SILK 数据推算时长（毫秒）；拿不到时返回 0，调用方自行按字数估算。
- (NSInteger)durationMsForSilk:(NSData*)silk;

// 微信自带编解码器是否已加载（用于面板/日志自检）
+ (BOOL)wechatCodecAvailable;
@end
