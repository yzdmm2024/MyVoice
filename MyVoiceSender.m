#import "MyVoiceSender.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceEngine.h"
#import "MyVoiceCloud.h"
#import "MyVoiceRecorder.h"
#import "MyVoiceManager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 发送（2.1.0 起改为「录音管线劫持」）
//
// 2.0.17 的做法与它为什么失败：
//   自己做 MJSilkCodec 编码 → 自己写 .silk 文件 → 自建 CMessageWrap(type 34) →
//   调 CMessageMgr -AddMsg:MsgWrap:。结果是「气泡出来了，但语音空白、没有声音」。
//   根因：语音消息的音频必须由微信自己的录音/上传链路注册（OnRecorderPart 分片入库、
//   OnRecorderEndRecording 构造 AudioRecorderUserData、SendOriVoiceMsgWithUserData 上传），
//   绕过这条链硬塞进去的消息，播放器拿不到音频 → 空白。
//
// 2.1.0 的做法（业界已验证，TTSFloat v29 同款）：
//   合成好的 PCM 装填进 MyVoiceRecorder，用户在当前聊天页「按住说话」时，
//   录音回调里把麦克风数据整块换成 TTS 数据；松手后走微信**完全真实**的录音发送链。
//   语音时长、SILK 编码、落盘、入库、上传、气泡全部由微信自己生成 —— 不会空白。
//
// ⚠️ 因此「发给谁」由用户当前打开的聊天决定：必须在目标聊天页里按住说话。
// ============================================================

@implementation MyVoiceSender

+ (instancetype)shared {
    static id s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

#pragma mark - 引擎选择

- (id<MyVoiceEngine>)engineForMode {
    if (MVEngineMode() == 1) {
        if (MVAPIKey().length && MVCurrentVoiceID().length) return [MyVoiceCloud shared];
        MVLog(@"[sender] 云端模式但未配置 Key/音色，回退离线 AVSpeech");
    }
    return [[NSClassFromString(@"MyVoiceAVSEngine") alloc] init];
}

#pragma mark - 主流程：合成 → 装填 → 等用户按住说话

- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID {
    if (!text.length) { MVLog(@"send 取消：文字为空"); return; }

    NSString *peer = (talker.length ? talker : [MyVoiceResolver currentTalker]);
    if (!peer.length) {
        MVLog(@"send 取消：未识别聊天对象（请先打开该聊天页）");
        [[MyVoiceManager shared] toast:@"未识别到聊天对象：请先打开微信聊天页"];
        return;
    }

    // 上一次还没被消费的装填先清掉，避免串台
    [MyVoiceRecorder cancelFeed];

    id<MyVoiceEngine> engine = [self engineForMode];
    NSString *vid = (MVEngineMode() == 1) ? (voiceID.length ? voiceID : MVCurrentVoiceID()) : voiceID;

    MVLog(@"合成中 talker=%@ mode=%ld len=%lu", peer, (long)MVEngineMode(), (unsigned long)text.length);
    [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"正在合成（发给 %@）…", peer]];

    [engine synthesizeText:text voiceID:vid completion:^(NSData *pcm, NSError *err){
        // ⚠️ 这个 block 在后台线程（离线=全局队列，云端=NSURLSession 回调）。
        //    SILK 编码/重采样是纯 CPU 活，留在后台；碰 UIKit/微信内部接口的必须回主线程。
        if (!pcm || err) {
            MVLog(@"合成失败 %@，回退占位音", err);
            pcm = [MyVoiceEngine placeholderPCM:text];
        }
        if (!pcm.length) { MVLog(@"send 取消：无 PCM"); return; }

        // 装填进录音管线（内部按管线采样率自适应重采样）
        NSUInteger ms = [MyVoiceRecorder feedPCM:pcm srcRate:MV_WECHAT_SR];
        if (!ms) {
            MVLog(@"[rec] 装填失败，无法发送");
            MVOnMain(^{ [[MyVoiceManager shared] toast:@"音频准备失败（先用面板的「测试配置」看自检）"]; });
            return;
        }

        double rate = [MyVoiceRecorder pipelineRate];
        MVLog(@"[send] ✅ 已装填 %.1fs 音频（管线采样率 %@）— 等待用户按住说话",
              ms / 1000.0, rate > 0 ? [NSString stringWithFormat:@"%.0fHz", rate] : @"待定(16k 假设)");

        MVOnMain(^{
            [[MyVoiceManager shared] toast:[NSString stringWithFormat:
                @"✅ 语音已就绪（%.1f 秒）\n请按住「按住 说话」，松开即发送", ms / 1000.0]];
        });
    }];
}

@end
