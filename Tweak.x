#import "MyVoiceCommon.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceRecorder.h"
#import <objc/runtime.h>

// ============================================================
// hook 一：会话捕获（2.0.14 起）
// 微信 8.0.75 实测：BaseMsgContentViewController 自身（含全部父类）**没有** talker 字段，
// 所以「扫字段找 wxid」永远失败。必须主动抓：
//   · 聊天页出现时（viewDidAppear:）—— VC 自己暴露 -getChatUserName / -GetContact
//   · 按住说话时（StartRecording:）—— 实测编码 B24@0:8@16（返回 BOOL、参数 id），必须原样返回
//   · 录音结束（StopRecording）—— 实测编码 v16@0:8（void，无参）
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

// ============================================================
// hook 二：微信录音管线（2.1.0 起，取代 2.0.17 的 AddMsg 直塞）
//
// 语音能不能发出去、有没有声音，取决于音频有没有走微信自己的录音→编码→上传链。
// 所以这里不再 hook 消息接口，而是给 AudioQueueNewInput 打补丁：
// 用户按住说话时，MyVoiceRecorder 会把麦克风数据整块换成已合成好的 TTS 数据，
// 松手后由微信自己完成 SILK 编码 / 落盘 / 入库 / 上传 / 气泡（详见 MyVoiceRecorder.m）。
// ============================================================

%ctor {
    @autoreleasepool {
        MVLog(@"载入 我的语音 v2.2.0（云端：CosyVoice / 千问 Qwen-TTS 可选；录音队列按队列精确绑定）");
        MVLog(@"日志文件：%@", MVLogFilePath() ?: @"(不可写，只能用 syslog)");
        [[MyVoiceManager shared] setup];

        // AudioQueueNewInput 补丁：随时可装，微信录音时才调用它。
        // 微信冷启动时 CoreAudio 已就绪，仍分几次重试（防止极早期调用尚未可用）。
        for (int i = 0; i < 5; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + i * 1.0) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [MyVoiceRecorder install]; });
        }
    }
}
