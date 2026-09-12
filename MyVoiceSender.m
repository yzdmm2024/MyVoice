#import "MyVoiceSender.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceEngine.h"
#import "MyVoiceCloud.h"
#import "MyVoiceRecorder.h"
#import "MyVoiceManager.h"
#import "MyVoiceDirectSend.h"
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
        BOOL hasKey = MVAPIKey().length > 0;
        // 千问用预置音色，不要求先克隆；CosyVoice 才必须有 voiceID
        BOOL hasVoice = (MVTTSProvider() == 1) || (MVCurrentVoiceID().length > 0);
        if (hasKey && hasVoice) return [MyVoiceCloud shared];
        MVLog(@"[sender] 云端模式但缺配置（Key=%@ 音色就绪=%@），回退离线 AVSpeech",
              hasKey ? @"有" : @"无", hasVoice ? @"是" : @"否");
        MVOnMain(^{ [[MyVoiceManager shared] toast:
            @"⚠️ 云端配置不全（Key/音色），本次用系统语音。\n请到 设置→我的语音 检查。"]; });
    }
    return [[NSClassFromString(@"MyVoiceAVSEngine") alloc] init];
}

#pragma mark - 主流程：合成 → 装填 → 等用户按住说话

- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID {
    if (!text.length) { MVLog(@"send 取消：文字为空"); return; }

    // 发送前先停掉任何正在进行的预览朗读，避免「预览外放」和「录音注入」同时发声造成重叠
    [MyVoiceEngine stopPreview];

    NSString *peer = (talker.length ? talker : [MyVoiceResolver currentTalker]);
    if (!peer.length) {
        MVLog(@"send 取消：未识别聊天对象（请先打开该聊天页）");
        [[MyVoiceManager shared] toast:@"未识别到聊天对象：请先打开微信聊天页"];
        return;
    }

    // 上一次还没被消费的装填先清掉，避免串台
    [MyVoiceRecorder cancelFeed];

    // 云端模式但没填 API Key：直接明确报错，别回退到本地 AVS 报一段看不懂的错。
    // 千问虽免克隆，但仍需要一个阿里云百炼(DashScope)的 API Key。
    if (MVEngineMode() == 1 && MVAPIKey().length == 0) {
        MVLog(@"合成失败：云端模式但未配置 API Key");
        MVOnMain(^{ [[MyVoiceManager shared] toast:
            @"❌ 未配置 API Key\n请到 设置→我的语音 填写阿里云百炼(DashScope) Key\n（千问 Qwen-TTS 有免费额度，填了就能用，无需下载任何语音）"]; });
        return;
    }

    id<MyVoiceEngine> engine = [self engineForMode];
    NSString *vid = voiceID;
    if (!vid.length && MVEngineMode() == 1) {
        vid = (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
    }

    MVLog(@"合成中 talker=%@ mode=%ld len=%lu", peer, (long)MVEngineMode(), (unsigned long)text.length);
    [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"正在合成（发给 %@）…", peer]];

    [engine synthesizeText:text voiceID:vid completion:^(NSData *pcm, NSError *err){
        // ⚠️ 这个 block 在后台线程（离线=全局队列，云端=NSURLSession 回调）。
        //    SILK 编码/重采样是纯 CPU 活，留在后台；碰 UIKit/微信内部接口的必须回主线程。
        if (!pcm || err || !pcm.length) {
            // 2.2.0：不再静默回退正弦占位音（用户会莫名其妙发出一段"嘟——"，还以为是模型问题）。
            //        合成失败就直接终止并明确报错。
            NSString *why = err.localizedDescription ?: @"返回音频为空";
            MVLog(@"合成失败：%@（已取消发送，不再回退占位音）", why);
            MVOnMain(^{ [[MyVoiceManager shared] toast:
                [NSString stringWithFormat:@"❌ 合成失败，未装填：%@", why]]; });
            return;
        }

        // 装填进录音管线（内部按管线采样率自适应重采样）
        NSUInteger ms = [MyVoiceRecorder feedPCM:pcm srcRate:MV_WECHAT_SR];
        if (!ms) {
            MVLog(@"[rec] 装填失败，无法发送");
            MVOnMain(^{ [[MyVoiceManager shared] toast:@"音频准备失败（先用面板的「测试配置」看自检）"]; });
            return;
        }

        double rate = [MyVoiceRecorder pipelineRate];
        MVLog(@"[send] ✅ 已装填 %.1fs 音频（管线采样率 %@）— 等待发送",
              ms / 1000.0, rate > 0 ? [NSString stringWithFormat:@"%.0fHz", rate] : @"待定(16k 假设)");

        MVOnMain(^{
            double dur = ms / 1000.0;

            // 手动模式：保持 2.1.0 的老交互（合成 → 用户自己按住说话）
            if (!MVAutoSend()) {
                [[MyVoiceManager shared] toast:[NSString stringWithFormat:
                    @"✅ 语音已就绪（%.1f 秒）\n请按住「按住 说话」，松开即发送", dur]];
                return;
            }

            // 自动直发：直接调微信内部录音接口，**不碰 UI**（不弹「松开 发送」界面）
            if (![MyVoiceDirectSend available]) {
                MVLog(@"[auto] 未找到微信内部录音入口，回退手动\n%@", [MyVoiceDirectSend diag]);
                [[MyVoiceManager shared] toast:[NSString stringWithFormat:
                    @"✅ 语音已就绪（%.1f 秒）\n（未找到直发入口）请按住「按住 说话」，松开即发送", dur]];
                return;
            }

            [[MyVoiceManager shared] toast:[NSString stringWithFormat:
                @"✅ 语音已就绪（%.1f 秒）\n正在自动发送（无需按住）…", dur]];

            [[MyVoiceDirectSend shared] sendArmedTo:peer duration:dur
                completion:^(BOOL ok, NSString *reason){
                    if (ok) {
                        MVLog(@"[auto] ✅ 无界面直发已提交");
                        [[MyVoiceManager shared] toast:@"✅ 已自动发送"];
                    } else {
                        MVLog(@"[auto] ❌ 直发失败：%@", reason);
                        [[MyVoiceManager shared] toast:[NSString stringWithFormat:
                            @"自动发送未生效：%@\n请手动按住「按住 说话」后松开", reason ?: @"未知原因"]];
                    }
                }];
        });
    }];
}

#pragma mark - 说明
// 2.2.4 起「自动发送」不再模拟点击「按住说话」按钮（那会展开界面且收不起来），
// 改为直接调微信内部录音接口的无界面直发，实现见 MyVoiceDirectSend.m。

@end
