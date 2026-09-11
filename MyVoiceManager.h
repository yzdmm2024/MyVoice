#import <Foundation/Foundation.h>

@interface MyVoiceManager : NSObject
+ (instancetype)shared;
- (void)setup;                  // 安装 hook、按设置创建浮动面板
- (void)handleSendText:(NSString*)text;  // 面板"发送"回调
- (NSString*)talkerStatus;               // 面板顶部状态行：现在会发给谁
- (void)toast:(NSString*)msg;
@end
