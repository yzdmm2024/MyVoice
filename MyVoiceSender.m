#import "MyVoiceSender.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceEngine.h"
#import "MyVoiceCloud.h"
#import "MyVoiceSILK.h"
#import "MyVoiceManager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 直发语音消息（修复 8.0.76 没声音）
// 旧方案 hook AudioQueue 把 PCM 塞进微信录音回调 —— 微信新版录音链路不走 AudioQueue，
// 因此合成音频进不去，气泡生成但无声。
// 新方案（参考 TTSFloat_v29）：合成 PCM → SILK 编码 → 调微信内部
//   sendVoiceToWeChat:toUsr:  直接构造语音消息发出。
// 目标类/选择器可在设置 sendClass 里微调（不同微信版本类名可能不同），默认 CMessageMgr。
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

#pragma mark - 发送主流程

- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID {
    if (!text.length) { MVLog(@"send 取消：文字为空"); return; }

    NSString *peer = (talker.length ? talker : [MyVoiceResolver currentTalker]);
    if (!peer.length) {
        MVLog(@"send 取消：未识别聊天对象（请先打开该聊天页）");
        [[MyVoiceManager shared] toast:@"未识别到聊天对象：请先打开微信聊天页"];
        return;
    }

    id<MyVoiceEngine> engine = [self engineForMode];
    NSString *vid = (MVEngineMode() == 1) ? (voiceID.length ? voiceID : MVCurrentVoiceID()) : voiceID;

    MVLog(@"合成中 talker=%@ mode=%ld len=%lu", peer, (long)MVEngineMode(), (unsigned long)text.length);
    [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"正在合成并发送给 %@", peer]];

    [engine synthesizeText:text voiceID:vid completion:^(NSData *pcm, NSError *err){
        // ⚠️ 这个 block 一定在后台线程执行（离线引擎=全局队列，云端引擎=NSURLSession 回调）。
        //    SILK 编码是纯 CPU 活，留在后台；但凡碰到微信内部接口/UI 的部分，
        //    必须 MVOnMain 回主线程 —— 否则微信 swizzle 过的 -addSubview: 会撞 AutoLayout 断言闪退。
        if (!pcm || err) {
            MVLog(@"合成失败 %@，回退占位音", err);
            pcm = [MyVoiceEngine placeholderPCM:text];
        }
        if (!pcm) { MVLog(@"send 取消：无 PCM"); return; }

        NSData *silk = [[MyVoiceSILK shared] encodePCM:pcm];
        if (!silk) {
            MVLog(@"[silk] 编码失败：本进程无 SILK 符号，无法直发");
            [[MyVoiceManager shared] toast:@"SILK 编码失败（请用 frida 脚本确认微信 SILK 符号）"];
            return;
        }
        MVOnMain(^{ [self directSend:silk toTalker:peer]; });
    }];
}

#pragma mark - 解析微信发送目标

// 返回 (target 实例, selector)。优先用设置里的 sendClass；否则按候选类 + 候选选择器自省。
- (BOOL)resolveSendTarget:(id*)outTarget selector:(SEL*)outSel {
    NSArray<NSString*> *classCands = nil;
    NSString *cfg = [MVPrefs() stringForKey:@"sendClass"];
    if (cfg.length) classCands = @[cfg];
    else classCands = @[@"CMessageMgr", @"MMMsgLogicManager", @"MessageLogicController",
                        @"CMessageWrap", @"WCMsgLogicManager"];

    NSArray<NSString*> *selCands = [MyVoiceResolver sendVoiceCandidates];

    for (NSString *cn in classCands) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        // 先尝试 MMServiceCenter 取服务实例（CMessageMgr 等单例）
        id target = [self serviceInstanceForClass:cls];
        if (!target) {
            @try { target = [[cls alloc] init]; } @catch (NSException *e) { target = nil; }
        }
        if (!target) continue;
        for (NSString *sn in selCands) {
            SEL s = NSSelectorFromString(sn);
            if (s && [target respondsToSelector:s]) {
                *outTarget = target; *outSel = s;
                MVLog(@"[sender] 命中发送目标 %@ -%@", cn, sn);
                return YES;
            }
        }
    }
    MVLog(@"[sender] 未找到可用的发送目标（类/选择器）。请用 frida 脚本确认微信版本对应的 sendVoiceToWeChat:toUsr: 所在类");
    return NO;
}

- (id)serviceInstanceForClass:(Class)cls {
    Class sc = NSClassFromString(@"MMServiceCenter");
    if (!sc) return nil;
    SEL dc = NSSelectorFromString(@"defaultCenter");
    if (![sc respondsToSelector:dc]) return nil;
    id center = ((id(*)(id,SEL))objc_msgSend)(sc, dc);
    if (!center) return nil;
    SEL gs = NSSelectorFromString(@"getService:");
    if (![center respondsToSelector:gs]) return nil;
    return ((id(*)(id,SEL,id))objc_msgSend)(center, gs, cls);
}

#pragma mark - 直发

- (void)directSend:(NSData*)silk toTalker:(NSString*)peer {
    id target = nil; SEL sel = NULL;
    if (![self resolveSendTarget:&target selector:&sel]) {
        [[MyVoiceManager shared] toast:@"未找到微信语音发送接口（见 frida 脚本）"];
        return;
    }
    @try {
        ((void(*)(id,SEL,id,id))objc_msgSend)(target, sel, silk, peer);
        MVLog(@"[sender] 已调用 sendVoiceToWeChat:toUsr: 直发 %lu bytes → %@", (unsigned long)silk.length, peer);
        [[MyVoiceManager shared] toast:@"已发送语音（克隆音色）"];
    } @catch (NSException *e) {
        MVLog(@"[sender] 直发异常 %@", e);
        [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"直发异常：%@", e.reason]];
    }
}

@end
