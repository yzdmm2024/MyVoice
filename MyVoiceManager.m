#import "MyVoiceManager.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceSender.h"
#import "MyVoicePanel.h"
#import <UIKit/UIKit.h>

@implementation MyVoiceManager
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

- (void)setup {
    [[MyVoiceSender shared] installHook];
    if (MVEnabled()) {
        [[MyVoicePanel shared] show];
        MVLog(@"已启用，浮动面板已创建");
    } else {
        MVLog(@"设置中未启用");
    }
    // 监听设置变更
    [[NSNotificationCenter defaultCenter] addObserverForName:@"com.yzdmm2024.myvoice/settings"
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n){
        BOOL on = MVEnabled();
        if (on) [[MyVoicePanel shared] show]; else [[MyVoicePanel shared] hide];
        MVLog(@"设置变更，启用=%d", on);
    }];
}

- (void)handleSendText:(NSString*)text {
    if (!MVEnabled()) { MVLog(@"未启用"); return; }
    // 聊天对象优先级：① VC 自动识别 → ② 捕获/持久化的会话
    NSString *talker = [MyVoiceResolver currentTalker];
    if (!talker.length) talker = [MyVoiceSender capturedToUsr];
    if (!talker.length) {
        MVLog(@"未识别到聊天对象");
        MVLog(@"%@", [MyVoiceResolver debugChatInfo]);
        [self toast:@"未识别到聊天对象：请先在微信聊天里按住说话一次（捕获会话）"];
        return;
    }
    MVLog(@"发送请求：talker=%@ text=%@", talker, text);
    [self toast:[NSString stringWithFormat:@"正在合成并发送给 %@", talker]];
    [[MyVoiceSender shared] sendText:text toTalker:talker voiceID:MVVoiceID()];
}

- (void)toast:(NSString*)msg {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = msg; l.font = [UIFont systemFontOfSize:13];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    l.layer.cornerRadius = 8; l.clipsToBounds = YES;
    l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
    CGSize s = [l.text boundingRectWithSize:CGSizeMake(240, 80)
                                    options:NSStringDrawingUsesLineFragmentOrigin
                                 attributes:@{NSFontAttributeName:l.font} context:nil].size;
    CGFloat wdt = MIN(260, s.width + 24), hgt = MAX(36, s.height + 16);
    l.frame = CGRectMake((w.bounds.size.width - wdt)/2, w.bounds.size.height - 120, wdt, hgt);
    [w addSubview:l];
    [UIView animateWithDuration:0.25 animations:^{ l.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; } completion:^(BOOL f){ [l removeFromSuperview]; }];
    });
}
@end
