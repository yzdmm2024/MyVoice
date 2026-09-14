#import <Foundation/Foundation.h>

@interface MyVoicePanel : NSObject
+ (instancetype)shared;
- (void)show;   // 创建/显示浮动语音球
- (void)hide;
- (void)togglePanel;   // 暴露给解锁验证: 解锁后打开面板
- (NSString*)resolvedVoiceID;   // ★ 2.8.26：当前面板选中的发送音色（与面板一致），供抖音 arming 取用
@end
