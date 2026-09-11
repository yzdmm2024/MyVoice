#import "MyVoiceCommon.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
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
// hook 二：抓 CMessageMgr -AddMsg:MsgWrap: 的第一个参数（2.0.17 直发链路用）
//
// 实测（v32@0:8@16@24）：两个参数都是对象。微信自己发/收消息时第一个参数永远是同一个
// 常量对象，而直发语音要复用这个对象 —— 所以在这里抓一份留着。
// 用运行时 hook（不写 @interface）：CMessageMgr 是私有类，%hook 需要接口声明，
// 用 method_setImplementation 更省事，也不影响别人后续 swizzle。
// ============================================================

static IMP g_mvOrigAddMsg = NULL;
static BOOL g_mvAddMsgHooked = NO;

static void mv_AddMsg(id self, SEL _cmd, id arg0, id wrap) {
    @autoreleasepool {
        @try { [MyVoiceResolver captureAddMsgArg0:arg0]; } @catch (NSException *e) {}
    }
    if (g_mvOrigAddMsg) ((void(*)(id,SEL,id,id))g_mvOrigAddMsg)(self, _cmd, arg0, wrap);
}

static void MVInstallAddMsgHook(void) {
    if (g_mvAddMsgHooked) return;
    Class c = objc_getClass("CMessageMgr");
    if (!c) return;
    Method m = class_getInstanceMethod(c, NSSelectorFromString(@"AddMsg:MsgWrap:"));
    if (!m) return;
    g_mvOrigAddMsg = method_getImplementation(m);
    method_setImplementation(m, (IMP)mv_AddMsg);
    g_mvAddMsgHooked = YES;
    MVLog(@"[hook] 已挂 CMessageMgr -AddMsg:MsgWrap:（抓 arg0）");
}

%ctor {
    @autoreleasepool {
        MVLog(@"载入 我的语音 v2.0.17（直发链路重做：MJSilkCodec 实例编码 + CMessageWrap/MsgMgr 真接口）");
        [[MyVoiceManager shared] setup];

        // 微信冷启动时类可能还没注册好，重试几次
        for (int i = 0; i < 8; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + i * 0.5) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ MVInstallAddMsgHook(); });
        }
    }
}
