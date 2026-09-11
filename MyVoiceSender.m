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
// 直发语音（2.0.17 重做）
//
// 为什么重做：老方案想调 `sendVoiceToWeChat:toUsr:` / 用 `silk_Encode` 裸符号 —— frida 实测
// 微信 8.0.75 **两者都不存在**，所以永远走到「编码失败」分支。
//
// 8.0.75 上实测可用的链路（本文件按此实现）：
//   ① 编码：MJSilkCodec 实例方式
//        - initWithEncoderWithSampleRate:24000   （编码实测：B24@0:8q16，参数是 long long）
//        - encodeFromPCMData:                    （@24@0:8@16，返回 SILK 的 NSData）
//      产物用 AudioUtil + calcSilkVoiceTime: 验证过：1s→1000 / 2s→2000 / 3s→3000 ms ✅
//      ⚠️ 别用类方法 +encodeToSilkFromPCMData:：它产出的数据微信自己算时长恒为 20，是另一套分帧
//   ② 消息体：CMessageWrap -initWithMsgType:34（34 = 语音）
//      169 个 ivar 里**没有**任何语音时长字段 → 时长由音频文件现算；
//      m_nsContent 放音频文件名，-getVoicePath 会算出微信期望的绝对路径
//   ③ 发送：CMessageMgr -AddMsg:MsgWrap:（实测 v32@0:8@16@24 → 两个参数都是对象）
//      第一个参数是微信自己传的常量对象，由 Tweak.x 里的 hook 抓下来复用（抓不到就传 nil）
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
        //    SILK 编码是纯 CPU 活，留在后台；碰微信内部接口的部分必须回主线程 ——
        //    否则微信 swizzle 过的 -addSubview: 会撞 AutoLayout 断言闪退（2.0.14 那次闪退）。
        if (!pcm || err) {
            MVLog(@"合成失败 %@，回退占位音", err);
            pcm = [MyVoiceEngine placeholderPCM:text];
        }
        if (!pcm) { MVLog(@"send 取消：无 PCM"); return; }

        MyVoiceSILK *codec = [MyVoiceSILK shared];
        NSData *silk = [codec encodePCM:pcm];
        if (!silk.length) {
            MVLog(@"[silk] 编码失败，无法直发");
            MVOnMain(^{ [[MyVoiceManager shared] toast:@"SILK 编码失败（先用面板的「测试配置」看自检）"]; });
            return;
        }
        // 自检：能不能解回 PCM（能解说明确实是微信认的 SILK）
        NSUInteger backLen = [codec pcmLengthFromSilk:silk];
        MVLog(@"[silk] 编码 %lu B PCM → %lu B SILK，解码自检 %lu B",
              (unsigned long)pcm.length, (unsigned long)silk.length, (unsigned long)backLen);

        MVOnMain(^{
            NSString *errMsg = nil;
            BOOL ok = [self directSendSilk:silk toTalker:peer error:&errMsg];
            if (ok) {
                [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已发语音 → %@", peer]];
            } else {
                [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"发送失败：%@", errMsg ?: @"未知"]];
            }
        });
    }];
}

#pragma mark - 音频文件落盘

// 问微信「这个文件名对应的语音绝对路径是什么」（CMessageWrap -getVoicePath 由 m_nsContent 算出）。
// 实测 169 个 ivar 里没有时长字段，说明音频文件本身就是权威 —— 所以必须放到微信认的位置。
// 返回：写成功的绝对路径；通过 outRelative 返回应该写进 m_nsContent 的值。
static NSString* MVWriteSilk(NSData *silk, NSString *fname, NSString **outContent) {
    NSMutableArray<NSString*> *cands = [NSMutableArray array];

    // ① 让微信自己算（最正确）
    Class W = NSClassFromString(@"CMessageWrap");
    if (W) {
        @try {
            id tmp = ((id(*)(id,SEL,long long))objc_msgSend)([W alloc],
                       NSSelectorFromString(@"initWithMsgType:"), 34LL);
            MVCall1(tmp, @"setM_nsContent:", fname);
            id vp = MVCall0(tmp, @"getVoicePath");
            if ([vp isKindOfClass:[NSString class]] && [vp length] && [vp hasPrefix:@"/"])
                [cands addObject:vp];
        } @catch (NSException *e) { MVLog(@"[send] getVoicePath 异常 %@", e.reason); }
    }
    // ② 兜底：自己的沙箱
    [cands addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:fname]];
    [cands addObject:[NSHomeDirectory() stringByAppendingPathComponent:fname]];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if ([silk writeToFile:p atomically:YES]) {
            MVLog(@"[send] SILK 已写入 %@（%lu B）", p, (unsigned long)silk.length);
            // 微信自己算出来的路径 → content 保持文件名；否则 content 直接给绝对路径
            *outContent = [cands.firstObject isEqualToString:p] ? fname : p;
            return p;
        }
        MVLog(@"[send] 写入失败（继续试下一个）：%@", p);
    }
    return nil;
}

#pragma mark - 直发

- (BOOL)directSendSilk:(NSData*)silk toTalker:(NSString*)peer error:(NSString**)errOut {
    NSString *err = [self sendSilkInternal:silk toTalker:peer];
    if (err) { if (errOut) *errOut = err; return NO; }
    return YES;
}

// 返回 nil = 成功；否则返回失败原因
- (NSString*)sendSilkInternal:(NSData*)silk toTalker:(NSString*)peer {
    Class W = NSClassFromString(@"CMessageWrap");
    if (!W) return @"微信版本不支持（CMessageWrap 缺失）";

    id mgr = MVService(@"CMessageMgr");
    if (!mgr) return @"取不到 CMessageMgr（微信可能还没登录完）";
    SEL addSel = NSSelectorFromString(@"AddMsg:MsgWrap:");
    if (![mgr respondsToSelector:addSel]) return @"微信没有 AddMsg:MsgWrap:";

    NSString *selfUsr = [MyVoiceResolver selfWxid];
    if (!selfUsr.length) return @"拿不到自己的 wxid";

    // 1) 落盘（顺便问出正确的 m_nsContent）
    NSString *fname = [NSString stringWithFormat:@"mv%ld.silk", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *content = fname;
    NSString *path = MVWriteSilk(silk, fname, &content);
    if (!path) return @"音频文件写不进去";

    // 2) 构造语音消息体
    id wrap = nil;
    @try {
        wrap = ((id(*)(id,SEL,long long))objc_msgSend)([W alloc],
                 NSSelectorFromString(@"initWithMsgType:"), 34LL);
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"构造消息体异常：%@", e.reason];
    }
    if (!wrap) return @"构造语音消息体失败";

    MVCall1(wrap, @"setM_nsFromUsr:", selfUsr);
    MVCall1(wrap, @"setM_nsToUsr:", peer);
    MVCall1(wrap, @"setM_nsContent:", content);
    MVSetInt(wrap, @"setM_uiCreateTime:", (unsigned int)[[NSDate date] timeIntervalSince1970]);
    MVSetInt(wrap, @"setM_uiMesLocalID:", 0);
    MVSetInt(wrap, @"setM_uiStatus:", 1);

    // 3) 时长自检（只打日志：时长由文件现算，不需要写进消息体）
    NSInteger ms = [[MyVoiceSILK shared] durationMsForSilk:silk];
    MVLog(@"[send] content=%@  path=%@  时长自检=%ldms  getVoicePath=%@",
          content, path, (long)ms, MVCall0(wrap, @"getVoicePath"));

    // 4) 发送。第一个参数用 hook 抓到的那个对象；没抓到就传 nil（微信内部拿它当上下文，nil 安全）
    id arg0 = [MyVoiceResolver capturedAddMsgArg0];
    MVLog(@"[send] AddMsg arg0 = %@（%@）", arg0,
          arg0 ? NSStringFromClass(object_getClass(arg0)) : @"未捕获→传 nil");
    @try {
        MVCallVoid2(mgr, @"AddMsg:MsgWrap:", arg0, wrap);
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"AddMsg 异常：%@", e.reason];
    }
    MVLog(@"[send] ✅ AddMsg 调用完成 → %@", peer);
    return nil;
}

@end
