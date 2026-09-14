#import "MyVoiceManager.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceSender.h"
#import "MyVoicePanel.h"
#import "MyVoiceDirectSend.h"
#import "MyVoiceDiag.h"
#import <UIKit/UIKit.h>

@implementation MyVoiceManager
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

// Darwin 通知回调（设置面板在另一个进程，NSNotificationCenter 过不来）
static void MVSettingsChanged(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // ★ 2.2.8：通知可能在宿主未就绪时到达（启动瞬间别的进程广播设置变更），
        //   此时建面板会触达宿主类 → 崩。丢掉即可：启动完成后的 setup 会读一次最新设置。
        if (!MVHostReady()) { MVLog(@"[setup] 宿主未就绪，忽略本次设置变更通知"); return; }
        BOOL on = MVEnabled();
        if (on) [[MyVoicePanel shared] show]; else [[MyVoicePanel shared] hide];
        MVLog(@"设置变更（跨进程），启用=%d 引擎=%ld 音色数=%lu",
              on, (long)MVEngineMode(), (unsigned long)MVVoices().count);
    });
}

// ============================================================
// ★ 2.2.8：由 Tweak.x 的 %ctor 延后调用（不再在 dyld 初始化期同步 setup）。
//
// 原来 %ctor 里直接 [[MyVoiceManager shared] setup]，而 %ctor 跑在**微信 dyld 初始化期**：
//   setup → [MyVoicePanel show] → refreshSession → [MyVoiceResolver currentTalker]
//         → MVService(@"CContactMgr") / NSClassFromString(宿主类) → 宿主 +initialize 💥
//
// 这里改成「轮询等宿主真的起来」再 setup。幂等，只会成功一次。
// hostReady 的两个条件全部只用系统 API，安全：
//   · MVHostReady()      = UIApplication 已创建（UIApplicationMain 跑过）
//   · anyWindow != nil   = 有可挂载的 window（面板要 addSubview）
// ============================================================
+ (BOOL)hostReady {
    if (!MVHostReady()) return NO;
    return [MyVoiceResolver anyWindow] != nil;
}

+ (void)setupWhenHostReady {
    MVOnMain(^{
        static BOOL done = NO;
        if (done) return;
        if (![self hostReady]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self setupWhenHostReady]; });
            return;
        }
        done = YES;
        [[self shared] setup];
        MVLog(@"[setup] 宿主已就绪，面板装配完成");
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
    // ★ 2.8.25：抖音进程里不走微信式发送（抖音无 wxid、无法程序化 startRecord）。
    //   点「合成语音」= 授权本次抖音 TTS 接管，引导用户去抖音长按语音键（半自动替换）。
    if (mvDiagIsDouyin()) {
        // ★ 2.8.26：用面板实际选中的音色，而不是按全局 ttsProvider 退化到千问默认（普通话）。
        //   否则克隆音色会被 MVQwenVoice() 覆盖，发出去的永远是普通话。
        NSString *vid = [[MyVoicePanel shared] resolvedVoiceID];
        if (!vid.length) vid = (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
        [MyVoiceDirectSend mvDouyinArmWithText:text voice:vid];
        [[MyVoiceManager shared] toast:@"抖音 TTS 已就绪：去聊天页长按语音键，听到『可以松手了』即松手发送"];
        return;
    }
    // 聊天对象：currentTalker 内部已经把「聊天页实时解析 → hook 捕获 → 落盘」串起来了。
    // ★ 2.3.0：识别不到 wxid 不再一票否决 —— 用户就在聊天页里时照样继续（发给谁由
    //   当前聊天页的录音上下文决定，Sender/DirectSend 会在启动录音前再解析一次）。
    NSString *talker = [MyVoiceResolver currentTalker];
    if (!talker.length) {
        MVLog(@"未识别到聊天对象（wxid）—— 若当前在聊天页则继续尝试\n%@", [MyVoiceResolver talkerDiag]);
    }
    MVLog(@"发送请求：talker=%@ text=%@", talker ?: @"(未识别)", text);
    // 2.1.0：不再直接发 —— 先把合成好的音频装填进录音管线，
    // 用户回到聊天页按住说话时才会真正发出去（见 MyVoiceSender 的说明）。
    // 音色按服务商取：千问用预置音色（qwenVoice），CosyVoice 用克隆音色（currentVoiceID）。
    NSString *vid = [[MyVoicePanel shared] resolvedVoiceID];
    if (!vid.length) vid = (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
    [[MyVoiceSender shared] sendText:text toTalker:talker voiceID:vid];
}

// 面板顶部显示的一行状态：一眼看出「现在会发给谁」
- (NSString*)talkerStatus {
    // ★ 2.8.25：抖音进程不显示误导性的「未识别（wxid）」，改为抖音 TTS 接管状态
    if (mvDiagIsDouyin()) {
        return [MyVoiceDirectSend mvDouyinArmed] ?
            @"抖音 TTS：已就绪（去长按语音键发送）" :
            @"抖音：点「合成语音」开启 TTS 接管";
    }
    NSString *t = [MyVoiceResolver currentTalker];
    if (t.length) {
        NSString *short_ = t.length > 18 ? [NSString stringWithFormat:@"…%@", [t substringFromIndex:t.length - 16]] : t;
        return [NSString stringWithFormat:@"会话: %@", short_];
    }
    return @"会话: 未识别（在聊天页里也可发送）";
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
    l.textColor = [UIColor colorWithWhite:0 alpha:0.85];
    l.backgroundColor = [UIColor colorWithWhite:1 alpha:0.88];
    l.layer.cornerRadius = 8; l.clipsToBounds = YES;
    l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
    CGSize s = [l.text boundingRectWithSize:CGSizeMake(240, 80)
                                    options:NSStringDrawingUsesLineFragmentOrigin
                                 attributes:@{NSFontAttributeName:l.font} context:nil].size;
    CGFloat wdt = MIN(260, s.width + 24), hgt = MAX(36, s.height + 16);
    l.frame = CGRectMake((w.bounds.size.width - wdt)/2, w.bounds.size.height * 0.28, wdt, hgt);
    [w addSubview:l];
    [UIView animateWithDuration:0.25 animations:^{ l.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; } completion:^(BOOL f){ [l removeFromSuperview]; }];
    });
}
@end
