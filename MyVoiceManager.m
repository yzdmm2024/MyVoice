#import "MyVoiceManager.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceSender.h"
#import "MyVoicePanel.h"
#import <UIKit/UIKit.h>

@implementation MyVoiceManager
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

// Darwin 通知回调（设置面板在另一个进程，NSNotificationCenter 过不来）
static void MVSettingsChanged(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL on = MVEnabled();
        if (on) [[MyVoicePanel shared] show]; else [[MyVoicePanel shared] hide];
        MVLog(@"设置变更（跨进程），启用=%d 引擎=%ld 音色数=%lu",
              on, (long)MVEngineMode(), (unsigned long)MVVoices().count);
    });
}

- (void)setup {
    if (MVEnabled()) {
        [[MyVoicePanel shared] show];
        MVLog(@"已启用，浮动面板已创建");
    } else {
        MVLog(@"设置中未启用");
    }
    // 监听跨进程设置变更（Darwin notify）
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, MVSettingsChanged,
                                    CFSTR(MV_CHANGED_NOTIFY), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)handleSendText:(NSString*)text {
    if (!MVEnabled()) { MVLog(@"未启用"); return; }
    // 聊天对象：currentTalker 内部已经把「聊天页实时解析 → hook 捕获 → 落盘」串起来了
    NSString *talker = [MyVoiceResolver currentTalker];
    if (!talker.length) {
        MVLog(@"未识别到聊天对象\n%@", [MyVoiceResolver talkerDiag]);
        [self toast:@"未识别到聊天对象。\n请打开目标聊天窗口（或在该窗口按住说话一次），\n再返回本面板发送。"];
        return;
    }
    MVLog(@"发送请求：talker=%@ text=%@", talker, text);
    // 2.1.0：不再直接发 —— 先把合成好的音频装填进录音管线，
    // 用户回到聊天页按住说话时才会真正发出去（见 MyVoiceSender 的说明）。
    // 音色按服务商取：千问用预置音色（qwenVoice），CosyVoice 用克隆音色（currentVoiceID）。
    NSString *vid = (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
    [[MyVoiceSender shared] sendText:text toTalker:talker voiceID:vid];
}

// 面板顶部显示的一行状态：一眼看出「现在会发给谁」
- (NSString*)talkerStatus {
    NSString *t = [MyVoiceResolver currentTalker];
    if (t.length) {
        NSString *short_ = t.length > 18 ? [NSString stringWithFormat:@"…%@", [t substringFromIndex:t.length - 16]] : t;
        return [NSString stringWithFormat:@"会话: %@", short_];
    }
    return @"会话: 未识别（打开聊天窗口）";
}

- (void)toast:(NSString*)msg {
    // ★ 关键：合成回调在后台队列上调用本方法，这里必须回主线程再加视图，
    //   否则会撞 CoreAutoLayout 的「非主线程」断言直接 abort（2.0.14 的闪退就是这么来的）。
    if (![NSThread isMainThread]) {
        MVOnMain(^{ [self toast:msg]; });
        return;
    }
    UIWindow *w = [MyVoiceResolver anyWindow];
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
