#import <Foundation/Foundation.h>

@interface MyVoiceManager : NSObject
+ (instancetype)shared;
- (void)setup;                  // 安装 hook、按设置创建浮动面板
- (void)handleSendText:(NSString*)text;  // 面板"发送"回调
- (void)toast:(NSString*)msg;
@end
