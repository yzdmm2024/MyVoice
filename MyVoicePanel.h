#import <Foundation/Foundation.h>

@interface MyVoicePanel : NSObject
+ (instancetype)shared;
- (void)show;   // 创建/显示浮动语音球
- (void)hide;
@end
