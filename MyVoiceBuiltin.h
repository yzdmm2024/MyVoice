#import <Foundation/Foundation.h>

// ★ 2.8.29：内置音色——把打包进 tweak 的「阳江话.mp3」作为参考音频复刻成一个 CosyVoice 克隆音色，
//   这样合成出来是【真·阳江话】（声线+口音都来自样本），而不是方言指令那种被引擎映射成广东话的近似。
//   首次在面板「选方言」里点「阳江话（内置样本克隆）」时联网复刻一次，之后缓存 voice_id，零等待复用。
@interface MyVoiceBuiltin : NSObject
+ (BOOL)isYangjiangEnrolled;
+ (NSString*)yangjiangVoiceID;
// 确保已复刻：已复刻直接回调缓存的 voice_id；否则写出 mp3 -> cloneVoiceWithName -> 写入 voices 列表。
+ (void)ensureYangjiangCompletion:(void(^)(NSString *voiceID, NSError *err))completion;
@end
