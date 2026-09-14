#import <Foundation/Foundation.h>

// ============================================================
// 无界面直发（2.2.4）
//
// 背景（2.2.3 真机反馈）：
//   2.2.3 的「自动发送」是**模拟点按「按住说话」按钮**（sendActionsForControlEvents
//   + 改长按手势 state）。这有两个硬伤：
//     ① 模拟的是"按钮"，所以必然会展开那个「松开 发送」界面 —— 用户根本不想要；
//     ② 微信的"松手发送"依赖真实触摸轨迹，靠改手势 state 经常不认 →
//        录音停不下来、界面收不起来（"不能自己关闭"）。
//
// 本模块改用 frida 实测到的**微信内部录音链路**直接启停（hook_wechat_voice.js 抓取）：
//     BaseMsgContentLogicController StartAudioRecording:
//       → RecordController   StartRecordingFromUsr:ToUsr:UserInfo:
//       → AudioSender        StartRecordFrom:ToUser:UserInfo:
//       → BaseAudioRecorder / SilkAudioRecorder  prepareQueue → AudioQueueNewInput
//     ...停止/发送：
//       → RecordController   StopRecordingInternal:
//       → AudioSender        StopRecord  →  prepareSend:
//     （取消：RecordController CancelRecording: / AudioSender CancelRecord）
//
// 于是：直接调内部接口起录音 → MyVoiceRecorder 把 TTS 灌进录音缓冲 →
// 时长到了直接调内部停止接口 —— 全程**不碰任何 UI**，不弹界面、不需要松手、
// 也不会有手势残留导致界面收不回去。
//
// 实例（RecordController / AudioSender）不硬编码，运行时从聊天页的
// m_delegate / 其 ivar 图里按**类名**捞（版本自适应，见 .m 的 locate）。
// 所有调用都按运行时方法签名构造 NSInvocation，参数类型不匹配也不会崩。
// ============================================================

@interface MyVoiceDirectSend : NSObject

+ (instancetype)shared;

// 是否具备直发条件（能找到微信内部录音控制器）。无 UI 调用，安全。
+ (BOOL)available;

// ★ 2.8.20：tweak 启动即挂 QQ 直发钩子（didTriggeredRecord/createRecorder/QQPushToTalkView，
// 带类加载重试）。供 Tweak.x 在 host-ready 时调用，需公开声明。
+ (void)installQQHooksIfNeeded;

// 无界面直发：TTS 必须已经装填进录音管线（MyVoiceRecorder feedPCM:）。
// 直接调微信内部接口开始录音 → 轮询确认录音真的被接管 → 到时长后停止并发送。
// completion(ok, reason)：ok=NO 时调用方应回退成「手动按住说话」提示。
- (void)sendArmedTo:(NSString*)talker
           duration:(double)seconds
         completion:(void(^)(BOOL ok, NSString *reason))completion;

// 诊断字符串（面板「测试配置」/ 日志用）
+ (NSString*)diag;

@end
