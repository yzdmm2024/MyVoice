#import <Foundation/Foundation.h>

@interface MyVoicePanel : NSObject
+ (instancetype)shared;
- (void)show;   // 创建/显示浮动语音球
- (void)hide;
- (void)togglePanel;   // 暴露给解锁验证: 解锁后打开面板
@end
