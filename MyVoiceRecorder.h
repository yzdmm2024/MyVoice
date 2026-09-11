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
// 本模块的做法（业界已验证：TTSFloat v29 同款）：
//   把 TTS 的 PCM 装填进待喂缓冲，用户在聊天页「按住说话」时，
//   在 AudioQueueNewInput 的输入回调里把麦克风采集到的数据**整块替换**成 TTS 数据
//   （整块填满、块内不留缝隙；TTS 耗尽后补静音帧保持节奏），
//   松手后微信以为这是刚录好的声音，自己编码 SILK、自己落盘、自己入库、自己上传发送。
//   于是「音色是云端克隆的、但一切元数据都是微信自己生成的」→ 不会空白。
//
// 采样率：微信录音管线实测为 **16kHz / 单声道 / S16**（buffer 8000B@250ms = 32000B/s）。
//   装填时会按 AudioQueueNewInput 报出的真实格式做一次自适应重采样，避免音调/时长错位。
// ============================================================

@interface MyVoiceRecorder : NSObject

+ (instancetype)shared;

// 打 AudioQueueNewInput 补丁（幂等，可反复调用）。由 Tweak.x 的 %ctor 装配。
+ (void)install;

// 装填待发送的 PCM。srcRate 是这段 PCM 的真实采样率（会按管线采样率自适应重采样）。
// 返回预计语音时长（毫秒）；返回 0 表示装填失败。
+ (NSUInteger)feedPCM:(NSData*)pcm srcRate:(double)srcRate;

// 取消装填（用户放弃 / 超时）
+ (void)cancelFeed;

// 是否已装填、正在等待用户「按住说话」
+ (BOOL)isArmed;

// 已喂入字节 / 总字节（面板显示进度用）
+ (NSUInteger)fedBytes;
+ (NSUInteger)totalBytes;

// 实测到的管线采样率（0 = 还没跑到过录音回调）
+ (double)pipelineRate;

// 诊断字符串（面板「测试配置」用）
+ (NSString*)diag;

@end
