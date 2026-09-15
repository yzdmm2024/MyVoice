#import "MyVoiceCommon.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceRecorder.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import "MyVoiceDiag.h"
#import "MyVoiceDirectSend.h"

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
        MVLog(@"载入 我的语音 v2.8.35（★ 「自建服务器」开关/地址已搬到【系统设置 → 我的语音 → 自建服务器】，悬浮面板点了只显示状态并指路；删除用不到的「对象存储 OSS」整组；并修「设置页改了不生效」—— 自建键改为 jbroot 共享域优先读取，且面板不再写这三个键。★ 2.8.33 新增「自建服务器」开关：本地 CosyVoice + 阿里云 ECS 中转免费克隆音色；开启后 CosyVoice 族走本地 server.py 不再耗额度。★ 2.8.32 修「千问合成失败·url error!」：合成端点改为按【模型家族】分流 —— Qwen-TTS(qwen3-tts-*) 走 multimodal-generation，Qwen-Audio-TTS(qwen-audio-3.0-tts-*) / CosyVoice 走 /services/audio/tts/SpeechSynthesizer；旧版按 provider 分流，千问克隆音色被送错端点 → 服务端 400 url error，与充值/额度无关。同时修好预置音色选「可调版」不生效、报错信息带端点）");
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

    // ④ 2.8.20：QQ 内启动即挂直发钩子（带类加载重试），确保用户切到语音模式时
    //   didMoveToWindow 已被钩住、能扣留 QQPushToTalkView；并保留类枚举诊断。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (mvDiagIsQQ()) {
            [MyVoiceDirectSend installQQHooksIfNeeded];
            mvDiagDumpClasses();
            MVLog(@"[mvdiag] QQ 直发钩子已挂：点「合成语音」即自动开始并发送（需处于语音模式）");
        }
        if (mvDiagIsDouyin()) {
            [MyVoiceDirectSend installDouyinHooksIfNeeded];
            MVLog(@"[mvdiag] 抖音半自动直发钩子已挂：按住语音键即合成 TTS 并替换录音文件发出");
        }
    });

    // ③ AudioQueueNewInput 补丁：与宿主无关，随时可装；微信冷启动 CoreAudio 就绪有先后，故重试
    for (int i = 0; i < 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + i * 1.0) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [MyVoiceRecorder install]; });
    }
}

// ============================================================
// 2.8.17 真机抓包：记录「按住说话」真实按钮类 + 其手势/action（仅打印）
//   关键：QQ 多半用 UILongPressGestureRecognizer 检测按下，而手势只由 UIKit
//   事件分发触发，直接调 [btn touchesBegan:] 不会让它 fire —— 这正是自动发送失效的根因。
//   这里在真机上把"按钮类 + 手势类 + action"原样打印出来，供下一步修复。
// ============================================================
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    // ★★ 2.8.35 耗电修复 ★★
    //   下面这段是 2.8.17 加的「真机抓包」诊断代码，以前是**无条件**跑的：
    //   每次触摸都要逐级 superview（最多 5 层）做 NSStringFromClass + 11 次
    //   containsString；命中（类名含 Btn/Button/Bar/Input/Tool/Voice/Record/Ptt，
    //   在 QQ 里遍地都是）还要拼层级/手势/UIControl 长字符串并写日志 —— 而 MVLog
    //   每条都是 NSLog + 开/seek/写/关文件。等于每点一下写一次盘。
    //   两个后果：① 没打开悬浮面板也在耗电；② 给事件分发加了延迟。
    //   现在：%orig 提到最前（热路径零额外延迟）+ 默认直接返回，
    //   要抓包再去【设置 → 我的语音 → 诊断（排查用）】打开开关。
    %orig;
    if (!mvDiagTapLogEnabled()) return;
    if (mvDiagIsQQ()) {
        NSSet *touches = [event touchesForWindow:self.keyWindow] ?: event.allTouches;
        for (UITouch *tc in touches) {
            if (tc.phase == UITouchPhaseBegan && tc.view) {
                UIView *v = tc.view;
                BOOL likely = NO; UIView *p = v; int d = 0;
                while (p && d < 5) {
                    NSString *pc = NSStringFromClass([p class]);
                    if ([pc containsString:@"Record"] || [pc containsString:@"Ptt"] ||
                        [pc containsString:@"Input"] || [pc containsString:@"Audio"] ||
                        [pc containsString:@"Voice"] || [pc containsString:@"Speak"] ||
                        [pc containsString:@"Press"] || [pc containsString:@"Bar"] ||
                        [pc containsString:@"Btn"] || [pc containsString:@"Button"] ||
                        [pc containsString:@"Tool"]) { likely = YES; break; }
                    p = [p superview]; d++;
                }
                if (likely) {
                    NSMutableString *line = [NSMutableString stringWithFormat:
                        @"[mvdiag] 触摸命中 %@ (window=%@)", NSStringFromClass([v class]),
                        (v.window ? NSStringFromClass([v.window class]) : (id)[NSNull null])];
                    UIView *pp = v; int dd = 0;
                    while ((pp = [pp superview]) && dd < 4) {
                        [line appendFormat:@" <- %@", NSStringFromClass([pp class])]; dd++;
                    }
                    if (v.gestureRecognizers.count) {
                        [line appendString:@" | GR:"];
                        for (UIGestureRecognizer *g in v.gestureRecognizers)
                            [line appendFormat:@" %@", mvDiagGRInfo(g)];
                    }
                    if ([v isKindOfClass:[UIControl class]])
                        [line appendFormat:@" | isUIControl=Y allTargets=%lu",
                            (unsigned long)[(UIControl *)v allTargets].count];
                    MVLog(@"%@", line);
                }
            }
        }
    }
}
%end
