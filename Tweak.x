#import "MyVoiceCommon.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceRecorder.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

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
    // ★ 2.2.9：抓取必须放在 %orig **之前**。
    //   微信在启动/切页时会在 viewDidAppear 内部自我销毁旧 VC，%orig 返回后 self
    //   就可能已经 dealloc —— 之后再碰 self 就是 use-after-free。
    [MyVoiceResolver captureFromChatVC:self];
    %orig;
    // 刚 appear 时 contact 可能还没挂上，0.8s 后再补抓一次更稳。
    // ★ 这里绝不能在 block 里捕获 self！0.8s 后它可能已被释放，而
    //   object_getClass(野指针) 会直接 SIGTRAP —— 2.2.8 的闪退就死在这一帧：
    //     isChatVC: ← talkerFromChatVC: ← captureFromChatVC: ← 主队列 block
    //   （SIGTRAP 不是 NSException，@try 抓不住，只能从源头不持有。）
    //   改走不持有任何对象的入口：到时重新从「活着的 VC 树」里取聊天页。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [MyVoiceResolver captureFromLatestChatVC];
    });
}

// 按住说话：返回值必须透传（编码 B24@0:8@16）
- (BOOL)StartRecording:(id)arg {
    // ★ 2.2.9：先抓（self 此刻必然活着），再原样透传返回值；%orig 之后不再碰 self
    [MyVoiceResolver captureFromChatVC:self];
    return %orig;
}

- (void)StopRecording {
    // ★ 2.2.9：先抓，再 %orig
    [MyVoiceResolver captureFromChatVC:self];
    %orig;
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
        // ⚠️ 这里跑在**微信进程 dyld 初始化期**（RootHide TweakInject 注入 → dlopen →
        //   runInitializersBottomUp）。微信自己的 ObjC 类此刻还没 realize！只要执行一次
        //   NSClassFromString(宿主类名)，就会触发它的 +initialize，而微信 +initialize
        //   内部会去读尚未就绪的单例 → SIGSEGV at 0x90。
        //
        //   2.2.7 的启动闪退就是这么来的：
        //     %ctor → [[MyVoiceManager shared] setup] → [MyVoicePanel show]
        //           → refreshSession → MVService/NSClassFromString → WeChat +initialize 💥
        //
        //   结论：%ctor 内**只允许**做与宿主完全无关的事（写日志、入队）。
        MVLog(@"载入 我的语音 v2.8.15（QQ 全自动发送：点合成语音无需先手动按住说话）");
        MVLog(@"宿主 App：%@（版本 %@）",
              [NSBundle mainBundle].bundleIdentifier ?: @"?",
              [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"?");
        MVLog(@"日志文件：%@", MVLogFilePath() ?: @"(不可写，只能用 syslog)");
    }

    // ① 面板/宿主类触达：延后到「微信启动完成」之后（MyVoiceManager 内部还有就绪轮询兜底）
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
            [MyVoiceManager setupWhenHostReady];
        }];
    });
    // ② 兜底：万一错过该通知（或微信走了不广播的启动路径），1.5s 后强制检查一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [MyVoiceManager setupWhenHostReady]; });

    // ③ AudioQueueNewInput 补丁：与宿主无关，随时可装；微信冷启动 CoreAudio 就绪有先后，故重试
    for (int i = 0; i < 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + i * 1.0) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [MyVoiceRecorder install]; });
    }
}
