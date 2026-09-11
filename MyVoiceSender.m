#import "MyVoiceSender.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceEngine.h"
#import <substrate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// 真实微信符号（从原 TTSFloat_v29 混淆表 XOR 解码还原，针对微信 8.0.7x）
//   AudioSender  = 微信录音/发送对象（含 StartRecordFrom:ToUser:UserInfo: / StopRecord）
//   StartRecordFrom:ToUser:UserInfo: = 启动一次真实录音会话
//   StopRecord   = 结束录音（触发微信真实 SILK 编码 + 上传 + 气泡）
// 发送真相：用 AudioSender 真实录音会话，把麦克风回调替换成 TTS 的 PCM，
//          微信自己完成后续编码/发送，不手动回传 userData（避免 use-after-free 闪退）。
// ============================================================
static NSString *const kAudioSenderCls = @"AudioSender";
static NSString *const kStartSel  = @"StartRecordFrom:ToUser:UserInfo:";
static NSString *const kStopSel   = @"StopRecord";

// 会话身份（来自 StartRecordFrom 观察 hook 捕获）
static NSString *g_lastToUsr = nil;          // 对方 wxid（聊天对象）
static id g_lastFromParam = nil;             // 自己身份（CContact 或 wxid）
static id g_lastUserInfoParam = nil;         // 录音会话 userData
static id g_audioSender = nil;               // 当前 AudioSender 实例

// 会话持久化 key（免捕捉：首次按住说话捕获后，跨启动直接可用）
static NSString *const kSessionFromKey = @"MyVoiceFrom";
static NSString *const kSessionToKey   = @"MyVoiceTo";
static NSString *const kSessionInfoKey = @"MyVoiceInfo";

// AudioQueue 注入：把麦克风输入回调替换成合成 PCM
static NSData *g_pendingPCM = nil;
static NSUInteger g_pcmOffset = 0;
static BOOL g_replaceActive = NO;
static BOOL g_pcmFedDone = NO;
static AudioQueueInputCallback g_origAQCallback = NULL;

static void MV_AQInputTrampoline(void *inUserData, AudioQueueRef inAQ,
                                 AudioQueueBufferRef inBuffer,
                                 const AudioTimeStamp *inStartTime,
                                 UInt32 inNumPackets,
                                 const AudioStreamPacketDescription *inPacketDesc) {
    if (g_replaceActive && g_pendingPCM && inBuffer && inBuffer->mAudioData) {
        @synchronized([MyVoiceSender class]) {
            NSUInteger total = g_pendingPCM.length;
            if (g_pcmOffset < total) {
                // 整块填满（块内不留间隙，避免杂音），耗尽后整块补零
                NSUInteger bufSz = inBuffer->mAudioDataByteSize;
                NSUInteger take = MIN(bufSz, total - g_pcmOffset);
                memcpy(inBuffer->mAudioData, (const char *)g_pendingPCM.bytes + g_pcmOffset, take);
                if (take < bufSz) memset((char *)inBuffer->mAudioData + take, 0, bufSz - take);
                g_pcmOffset += take;
            } else {
                memset(inBuffer->mAudioData, 0, inBuffer->mAudioDataByteSize);
                if (!g_pcmFedDone) { g_pcmFedDone = YES; MVLog(@"[aq] PCM 全部喂完"); }
            }
        }
    }
    if (g_origAQCallback)
        g_origAQCallback(inUserData, inAQ, inBuffer, inStartTime, inNumPackets, inPacketDesc);
}

// 原始 AudioQueueNewInput
typedef OSStatus (*AQNewInputOrig)(const AudioStreamBasicDescription*, AudioQueueInputCallback, void*, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef*);
static AQNewInputOrig orig_AudioQueueNewInput = NULL;

static OSStatus MV_AudioQueueNewInput(const AudioStreamBasicDescription *inFormat,
                                     AudioQueueInputCallback inCallback, void *inUserData,
                                     CFRunLoopRef inRunLoop, CFStringRef inMode,
                                     UInt32 inFlags, AudioQueueRef *outAQ) {
    g_origAQCallback = inCallback;
    if (g_replaceActive) MVLog(@"AudioQueueNewInput 拦截 → 注入合成 PCM");
    return orig_AudioQueueNewInput(inFormat, MV_AQInputTrampoline, inUserData, inRunLoop, inMode, inFlags, outAQ);
}

#pragma mark - 会话身份捕获 / 持久化

+ (void)persistSessionFrom:(id)from to:(id)to info:(id)info {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([to isKindOfClass:[NSString class]] && [(NSString*)to length])
        [d setObject:to forKey:kSessionToKey];
    if ([from isKindOfClass:[NSString class]] && [(NSString*)from length])
        [d setObject:from forKey:kSessionFromKey];
    if ([info isKindOfClass:[NSDictionary class]] && [(NSDictionary*)info count]) {
        @try {
            NSData *jd = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
            if (jd) [d setObject:[jd base64EncodedStringWithOptions:0] forKey:kSessionInfoKey];
        } @catch (NSException *e) {}
    }
}

+ (NSString*)capturedToUsr {
    if (g_lastToUsr.length) return g_lastToUsr;
    return [[NSUserDefaults standardUserDefaults] stringForKey:kSessionToKey];
}
+ (NSString*)capturedFrom {
    if ([g_lastFromParam isKindOfClass:[NSString class]] && [(NSString*)g_lastFromParam length])
        return g_lastFromParam;
    return [[NSUserDefaults standardUserDefaults] stringForKey:kSessionFromKey];
}
+ (NSDictionary*)capturedUserInfo {
    if ([g_lastUserInfoParam isKindOfClass:[NSDictionary class]]) return g_lastUserInfoParam;
    NSString *b64 = [[NSUserDefaults standardUserDefaults] stringForKey:kSessionInfoKey];
    if (!b64.length) return nil;
    NSData *jd = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!jd) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}

+ (id)audioSenderInstance {
    @synchronized([MyVoiceSender class]) {
        if (g_audioSender) return g_audioSender;
        Class cls = NSClassFromString(kAudioSenderCls);
        if (cls) {
            @try {
                id fresh = [[cls alloc] init];
                if (fresh) { g_audioSender = fresh; MVLog(@"[sender] AudioSender 现场创建 %p（免捕捉）", (__bridge void*)fresh); }
            } @catch (NSException *e) { MVLog(@"[sender] AudioSender 创建失败: %@", e); }
        }
        return g_audioSender;
    }
}

#pragma mark - hook 安装

- (void)installHook {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 1) AudioQueue 注入
        void *h = dlsym(RTLD_DEFAULT, "AudioQueueNewInput");
        if (h && !orig_AudioQueueNewInput) {
            MSHookFunction((void*)AudioQueueNewInput, (void*)MV_AudioQueueNewInput, (void**)&orig_AudioQueueNewInput);
            MVLog(@"AudioQueueNewInput hook 已安装");
        } else {
            MVLog(@"AudioQueueNewInput hook 安装失败");
        }
        // 2) StartRecordFrom 观察 hook（捕获会话身份，免手动填）
        Class cls = NSClassFromString(kAudioSenderCls);
        if (!cls) { MVLog(@"[obs] 未找到 AudioSender 类"); return; }
        SEL sel = NSSelectorFromString(kStartSel);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { MVLog(@"[obs] StartRecordFrom MISS（微信版本可能已改名，待日志确认）"); return; }
        IMP old = method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, id from, id toUsr, id userInfo) {
            @synchronized([MyVoiceSender class]) {
                g_lastFromParam = from;
                g_lastToUsr = toUsr;
                g_lastUserInfoParam = userInfo;
                g_audioSender = self;
                [MyVoiceSender persistSessionFrom:from to:toUsr info:userInfo];
            }
            MVLog(@"[obs] 捕获会话 from=%@ to=%@", from, toUsr);
            return ((BOOL(*)(id,SEL,id,id,id))old)(self, sel, from, toUsr, userInfo);
        });
        method_setImplementation(m, newImp);
        MVLog(@"[obs] StartRecordFrom 观察 hook 已装");
    });
}

#pragma mark - 发送（文字 → 合成 → 注入真实录音链）

- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID {
    if (!text.length) { MVLog(@"send 取消：文字为空"); return; }

    // 聊天对象优先级：面板传入（VC 自动识别）→ 捕获/持久化
    NSString *peer = (talker.length ? talker : [MyVoiceSender capturedToUsr]);
    if (!peer.length) {
        MVLog(@"send 取消：无聊天对象（请先在微信聊天里按住说话一次以捕获会话）");
        return;
    }
    NSString *myWxid = [MyVoiceSender capturedFrom];
    NSDictionary *userInfo = [MyVoiceSender capturedUserInfo];
    id sender = [MyVoiceSender audioSenderInstance];
    if (!sender) { MVLog(@"send 取消：无 AudioSender 实例"); [MyVoiceSender cleanup]; return; }

    MVLog(@"合成中 talker=%@ len=%lu", peer, (unsigned long)text.length);
    [[MyVoiceEngine defaultEngine] synthesizeText:text voiceID:voiceID completion:^(NSData *pcm, NSError *err){
        if (!pcm || err) { MVLog(@"合成失败：%@", err); [MyVoiceSender cleanup]; return; }
        @synchronized([MyVoiceSender class]) {
            g_pendingPCM = pcm; g_pcmOffset = 0; g_replaceActive = YES; g_pcmFedDone = NO;
        }
        MVLog(@"PCM 装填 %lu bytes ≈ %lums — 启动录音会话",
              (unsigned long)pcm.length,
              (unsigned long)(pcm.length*1000/(NSUInteger)([MyVoiceEngine sampleRate]*2)));

        SEL startSel = NSSelectorFromString(kStartSel);
        BOOL ok = NO;
        @try {
            BOOL (*fn)(id,SEL,id,id,id) = (BOOL(*)(id,SEL,id,id,id))objc_msgSend;
            ok = fn(sender, startSel, myWxid, peer, userInfo ?: @{});
            MVLog(@"StartRecord ret=%d", ok);
        } @catch (NSException *e) { MVLog(@"StartRecord 异常：%@", e); }

        if (!ok) {
            MVLog(@"StartRecord 返回 NO（请先在微信聊天里按住说话一次以捕获会话身份）");
            @synchronized([MyVoiceSender class]) { g_replaceActive = NO; }
            [MyVoiceSender cleanup];
            return;
        }
        // 轮询等 PCM 喂完（g_pcmFedDone）再 StopRecord，避免截断
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            NSUInteger ms = pcm.length * 1000 / (NSUInteger)([MyVoiceEngine sampleRate]*2);
            int capMs = 15000 + 2*(int)ms;
            int waited = 0; BOOL fed = NO;
            while (waited < capMs) {
                [NSThread sleepForTimeInterval:0.1]; waited += 100;
                @synchronized([MyVoiceSender class]) { fed = g_pcmFedDone; }
                if (fed) { [NSThread sleepForTimeInterval:0.3]; break; }
            }
            [self finishRecording:sender];
        });
    }];
}

- (void)finishRecording:(id)sender {
    SEL stopSel = NSSelectorFromString(kStopSel);
    @try {
        ((void(*)(id,SEL))objc_msgSend)(sender, stopSel);
        MVLog(@"StopRecord done");
    } @catch (NSException *e) { MVLog(@"StopRecord 异常：%@", e); }
    // 稍后复位（等微信真实结束链跑完）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized([MyVoiceSender class]) { g_replaceActive = NO; g_pcmFedDone = NO; }
        MVLog(@"[sender] 本次发送结束，等待微信真实链完成");
    });
}

+ (void)cleanup {
    @synchronized([MyVoiceSender class]) { g_replaceActive = NO; g_pendingPCM = nil; g_pcmOffset = 0; g_pcmFedDone = NO; }
}

@end
