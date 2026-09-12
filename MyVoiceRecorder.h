#import <Foundation/Foundation.h>

// ============================================================
// 微信录音管线劫持（2.1.0 起，取代「自己编码 + 硬塞 AddMsg」）
//
// 为什么换掉旧方案（2.0.17 实测「语音发出去空白、没声音」）：
//   自建 CMessageWrap(type 34) + 写 m_nsContent 指向的文件 + CMessageMgr -AddMsg:MsgWrap:，
//   气泡是能出来，但**音频文件从未被微信的消息/上传链路注册**，播放器拿不到音频 → 空白。
//   微信自己的语音发送链是：
//       AudioQueueNewInput（麦克风）
//         → OnOutputPcmBuffer:UserData:（PCM 帧）
//         → OnRecorderPart:Offset:Len:EndFlag:ForceDelete:Duration:（分片入库）
//         → OnRecorderEndRecording:（构造 AudioRecorderUserData）
//         → SendOriVoiceMsgWithUserData: → prepareSend:（上传 + 入库 + 气泡）
//   只有这条链能产出「可播放、时长正确」的语音消息。
//
// 本模块的做法（与业界已验证实现 TTSFloat v29 完全对齐）：
//   把 TTS 的 PCM 装填进待喂缓冲，在 AudioQueueNewInput 的输入回调里把麦克风采集到的
//   数据**整块替换**成 TTS 数据（整块填满、块内不留缝隙；TTS 耗尽后补静音帧保持节奏），
//   微信以为这是刚录好的声音，自己编码 SILK、自己落盘、自己入库、自己上传发送。
//
// ★ 2.2.5 版核心修正（对齐参考实现）：
//   1) 【单一数据流】全局只保留**一份**喂入偏移与**一份**重采样副本。
//      2.2.4 曾让"每个队列各自从头喂一份完整 TTS"——只要设备上同时有两个输入队列
//      （录音器 + AEC/电平表/VoIP 等），同一段话就会被喂进两条流 → 听起来就是叠音/重音。
//   2) 【精确绑定】只替换"本次启动录音后新建的那一个队列"（beginQueueBinding 之后第一个
//      登记/回调的队列），其它队列**原样不动**，从根上杜绝两路声音。
//   3) 【不会半截】提供 fedDone 供发送方等待"TTS 真正喂完"再 StopRecord
//      （按预估时长定时 Stop 会截断数据 → 微信等完整数据 → 转圈/好久不出来）。
//   4) 【不残留】发送收尾后主动清除 armed 状态，避免后续真实录音被注入静音。
//
// 采样率：主档 PCM 统一 16kHz / 单声道 / S16（微信录音管线实测值）。
//   重采样按【绑定队列】自己创建时申报的格式做一次；拿不到就按 16kHz 直喂。
// ============================================================

@interface MyVoiceRecorder : NSObject

+ (instancetype)shared;

// 打 AudioQueueNewInput 补丁（幂等，可反复调用）。由 Tweak.x 的 %ctor 装配。
+ (void)install;

// 装填待发送的 PCM。srcRate 是这段 PCM 的真实采样率（会按绑定队列采样率自适应重采样）。
// 返回预计语音时长（毫秒）；返回 0 表示装填失败。
+ (NSUInteger)feedPCM:(NSData*)pcm srcRate:(double)srcRate;

// ★ 2.2.5：在【调用微信内部录音启动方法之前】调用。
//   把"接下来新建的第一个输入队列"认作本次要替换的队列（精确绑定，只替换它）。
+ (void)beginQueueBinding;

// 取消装填（用户放弃 / 超时）
+ (void)cancelFeed;

// 发送收尾：delay 秒后清除 armed/装填状态（防止残留影响后续真实录音）。
+ (void)resetAfterSend:(NSTimeInterval)delay;

// 是否已装填、正在等待发送
+ (BOOL)isArmed;

// 已喂入字节 / 总字节（面板显示进度用）
+ (NSUInteger)fedBytes;
+ (NSUInteger)totalBytes;

// ★ 2.2.5：TTS 是否已全部喂进录音管线（发送方据此决定 StopRecord 时机）
+ (BOOL)fedDone;

// 绑定队列申报的采样率（0 = 还没绑定/未知）
+ (double)pipelineRate;

// 诊断字符串（面板「测试配置」用）
+ (NSString*)diag;

@end
