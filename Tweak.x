#import "MyVoiceCommon.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"

// ============================================================
// 会话捕获 hook
// 微信 8.0.75 实测：BaseMsgContentViewController 自身（含全部父类）**没有** talker 字段，
// 所以「扫字段找 wxid」永远失败。必须主动抓：
//   · 聊天页出现时（viewDidAppear:）—— VC 自己暴露 -getChatUserName / -GetContact
//   · 按住说话时（StartRecording:）—— 实测编码 B24@0:8@16（返回 BOOL、参数 id），必须原样返回
//   · 录音结束（StopRecording）—— 实测编码 v16@0:8（void，无参）
// 抓到就落到共享配置（lastTalker），即使实时解析失败也能兜住。
// ============================================================

%hook BaseMsgContentViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [MyVoiceResolver captureFromChatVC:self];
    // 刚 appear 时 contact 可能还没挂上，0.8s 后再抓一次更稳
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [MyVoiceResolver captureFromChatVC:self];
    });
}

// 按住说话：返回值必须透传（编码 B24@0:8@16）
- (BOOL)StartRecording:(id)arg {
    BOOL r = %orig;
    [MyVoiceResolver captureFromChatVC:self];
    return r;
}

- (void)StopRecording {
    %orig;
    [MyVoiceResolver captureFromChatVC:self];
}

%end

%ctor {
    @autoreleasepool {
        MVLog(@"载入 我的语音 v2.0.14（会话识别重写：getChatUserName/GetContact + 聊天页捕获）");
        [[MyVoiceManager shared] setup];
    }
}
