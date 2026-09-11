#import "MyVoiceSender.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceEngine.h"
#import <substrate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>

// 原 C 函数指针
typedef OSStatus (*AQNewInputOrig)(const AudioStreamBasicDescription*, AudioQueueInputCallback, void*, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef*);
static AQNewInputOrig orig_AudioQueueNewInput = NULL;
static AudioQueueInputCallback g_origCallback = NULL;
static void *g_origUD = NULL;

// 合成 PCM 状态
static NSData *g_pcm = nil;
static NSUInteger g_offset = 0;
static BOOL g_active = NO;
static BOOL g_didFinish = NO;

static void MV_AQInputCallback(void* inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer,
                               const AudioTimeStamp* inStartTime, UInt32 inNumPackets,
                               const AudioStreamPacketDescription* inPacketDesc) {
    if (!g_active) {
        // 非合成模式：直通麦克风（正常录音不受影响）
        if (g_origCallback) g_origCallback(inUserData, inAQ, inBuffer, inStartTime, inNumPackets, inPacketDesc);
        return;
    }
    NSUInteger cap = inBuffer->mAudioDataBytesCapacity;
    @synchronized([MyVoiceSender class]) {
        NSUInteger remain = g_pcm.length - g_offset;
        if (remain > 0) {
            NSUInteger copy = MIN(cap, remain);
            memcpy(inBuffer->mAudioData, (const char*)g_pcm.bytes + g_offset, copy);
            g_offset += copy;
            inBuffer->mAudioDataByteSize = (UInt32)copy;
        } else {
            memset(inBuffer->mAudioData, 0, cap);
            inBuffer->mAudioDataByteSize = (UInt32)cap;
            if (!g_didFinish) {
                g_didFinish = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ [MyVoiceSender finishRecording]; });
            }
        }
    }
}

static OSStatus MV_AudioQueueNewInput(const AudioStreamBasicDescription* inFormat,
                                     AudioQueueInputCallback inCallback, void* inUserData,
                                     CFRunLoopRef inRunLoop, CFStringRef inMode,
                                     UInt32 inFlags, AudioQueueRef* outAQ) {
    g_origCallback = inCallback;
    g_origUD = inUserData;
    if (g_active) MVLog(@"AudioQueueNewInput 拦截 → 注入合成 PCM");
    return orig_AudioQueueNewInput(inFormat, MV_AQInputCallback, inUserData, inRunLoop, inMode, inFlags, outAQ);
}

@implementation MyVoiceSender
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

- (void)installHook {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlsym(RTLD_DEFAULT, "AudioQueueNewInput");
        if (h && !orig_AudioQueueNewInput) {
            MSHookFunction((void*)AudioQueueNewInput, (void*)MV_AudioQueueNewInput, (void**)&orig_AudioQueueNewInput);
            MVLog(@"AudioQueueNewInput hook 已安装");
        } else {
            MVLog(@"AudioQueueNewInput hook 安装失败");
        }
    });
}

- (UIViewController*)findChatVC:(Class)cls {
    NSMutableArray *stack = [NSMutableArray array];
    UIViewController *rvc = [MyVoiceResolver topViewController];
    if (rvc) [stack addObject:rvc];
    while (stack.count) {
        UIViewController *vc = stack.lastObject; [stack removeLastObject];
        if (cls && [vc isKindOfClass:cls]) return vc;
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    return nil;
}

- (void)sendText:(NSString*)text toTalker:(NSString*)talker voiceID:(NSString*)voiceID {
    if (!text.length || !talker.length) { MVLog(@"send 取消：text=%lu talker=%lu", (unsigned long)text.length, (unsigned long)talker.length); return; }
    MVLog(@"开始合成：talker=%@ len=%lu", talker, (unsigned long)text.length);
    [[MyVoiceEngine defaultEngine] synthesizeText:text voiceID:voiceID completion:^(NSData* pcm, NSError* err){
        if (!pcm || err) { MVLog(@"合成失败：%@", err); return; }
        @synchronized([MyVoiceSender class]) { g_pcm = pcm; g_offset = 0; g_active = YES; g_didFinish = NO; }
        [self startWeChatRecording:talker];
    }];
}

- (void)startWeChatRecording:(NSString*)talker {
    Class chatCls = [MyVoiceResolver classWithCandidates:[MyVoiceResolver chatVCCandidates]];
    UIViewController *vc = [self findChatVC:chatCls];
    if (!vc) { MVLog(@"未找到聊天 VC，无法触发录音"); [MyVoiceSender cleanup]; return; }
    SEL sel = [MyVoiceResolver selectorWithCandidates:[vc class] names:[MyVoiceResolver recordStartCandidates]];
    if (!sel) {
        MVLog(@"未解析到录音开始方法，VC=%@ 候选方法含 Record/Voice/Send 的有：", NSStringFromClass([vc class]));
        unsigned int mc=0; Method *ms = class_copyMethodList([vc class], &mc);
        for (unsigned int i=0;i<mc;i++){
            NSString *sn = NSStringFromSelector(method_getName(ms[i]));
            if ([sn containsString:@"ecord"]||[sn containsString:@"oice"]||[sn containsString:@"end"]||[sn containsString:@"Send"]) {
                MVLog(@"   %@", sn);
            }
        }
        free(ms);
        [MyVoiceSender cleanup]; return;
    }
    NSMethodSignature *sig = [[vc class] instanceMethodSignatureForSelector:sel];
    if (!sig) { MVLog(@"无方法签名：%@", NSStringFromSelector(sel)); [MyVoiceSender cleanup]; return; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = vc; inv.selector = sel;
    NSUInteger nargs = sig.numberOfArguments - 2;
    for (NSUInteger i = 0; i < nargs; i++) {
        if (i == 0) [inv setArgument:&talker atIndex:2+i];
        else { id nilArg = nil; [inv setArgument:&nilArg atIndex:2+i]; }
    }
    @try { [inv invoke]; MVLog(@"已触发微信录音：%@ @ %@", NSStringFromSelector(sel), NSStringFromClass([vc class])); }
    @catch (NSException *e) { MVLog(@"触发录音异常：%@", e); [MyVoiceSender cleanup]; }
}

+ (void)finishRecording {
    UIViewController *rvc = [MyVoiceResolver topViewController];
    Class chatCls = [MyVoiceResolver classWithCandidates:[MyVoiceResolver chatVCCandidates]];
    UIViewController *vc = nil;
    NSMutableArray *stack = [NSMutableArray array];
    if (rvc) [stack addObject:rvc];
    while (stack.count) {
        UIViewController *c = stack.lastObject; [stack removeLastObject];
        if (chatCls && [c isKindOfClass:chatCls]) { vc = c; break; }
        for (UIViewController *ch in c.childViewControllers) [stack addObject:ch];
        if (c.presentedViewController) [stack addObject:c.presentedViewController];
    }
    if (vc) {
        SEL sel = [MyVoiceResolver selectorWithCandidates:[vc class] names:[MyVoiceResolver recordEndCandidates]];
        if (sel) {
            NSMethodSignature *sig = [[vc class] instanceMethodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = vc; inv.selector = sel;
                @try { [inv invoke]; MVLog(@"已触发录音结束/发送：%@", NSStringFromSelector(sel)); }
                @catch (NSException *e) { MVLog(@"结束录音异常：%@", e); }
            }
        } else {
            MVLog(@"未解析到录音结束方法（微信可能已在内部自行结束）");
        }
    }
    [[self class] cleanup];
}

+ (void)cleanup {
    @synchronized([MyVoiceSender class]) { g_active = NO; g_pcm = nil; g_offset = 0; g_didFinish = NO; }
}

@end
