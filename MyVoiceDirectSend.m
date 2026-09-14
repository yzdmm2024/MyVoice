#import "MyVoiceDirectSend.h"
#import "MyVoiceCommon.h"
#import "MyVoiceResolver.h"
#import "MyVoiceRecorder.h"
#import "MyVoiceManager.h"
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "MyVoiceDiag.h"

// Substrate / ellekit 均提供（同 MSHookFunction）
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

// 私有声明：保证「后面定义、前面调用」不会触发
// "no known class method for selector"（这个在 ObjC 里是**错误**，不是警告）。
@interface MyVoiceDirectSend ()
+ (NSArray<NSString*>*)recordControllerNames;
+ (NSArray<NSString*>*)audioSenderNames;
+ (id)locate:(NSArray<NSString*>*)names;
+ (id)recordController;
+ (id)audioSender;
+ (NSString*)stopWith:(id)stopTarget sender:(BOOL)isSender fallbackRC:(id)rc qqMode:(BOOL)qqMode;
+ (id)stashedQQOperator;
+ (id)stashedQQRecorder;
+ (id)qqAutoPressRecordButton:(BOOL*)outStarted;
+ (UITouch*)mvSyntheticTouchOnView:(UIView*)view phase:(UITouchPhase)phase;
+ (id)qqFindRecordButton;
+ (BOOL)qqAvailable;
+ (void)cancelWith:(id)stopTarget sender:(BOOL)isSender fallbackRC:(id)rc;
@end

// ============================================================
// 1) 通用调用：按【运行时方法签名】构造 NSInvocation
//
//    为什么不用 objc_msgSend 强转：微信内部方法的参数类型/个数不确定
//    （StopRecordingInternal: 到底吃 BOOL 还是 id 无从得知），强转一旦猜错就是
//    ABI 不匹配 → 崩溃。用 NSMethodSignature + NSInvocation 按真实类型填参数，
//    猜不到的参数一律填 0/nil，最坏情况是"没生效"，不会崩。
// ============================================================
static id MVInvoke(id obj, NSString *selName, NSArray *args) {
    if (!obj || !selName.length) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (!sel || ![obj respondsToSelector:sel]) return nil;
    @try {
        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = obj;
        inv.selector = sel;

        NSUInteger n = sig.numberOfArguments;
        for (NSUInteger i = 2; i < n; i++) {
            const char *t = [sig getArgumentTypeAtIndex:i];
            if (!t || !t[0]) continue;
            NSUInteger ai = i - 2;
            id a = (args && ai < args.count) ? args[ai] : nil;
            BOOL hasVal = a && ![a isKindOfClass:[NSNull class]];

            if (t[0] == '@' || t[0] == '#') {
                id v = hasVal ? a : nil;
                [inv setArgument:&v atIndex:i];
            } else if (hasVal && (t[0]=='c'||t[0]=='s'||t[0]=='i'||t[0]=='l'||t[0]=='q'||
                                  t[0]=='C'||t[0]=='S'||t[0]=='I'||t[0]=='L'||t[0]=='Q'||t[0]=='B')) {
                long long v = [a longLongValue];
                NSUInteger sz = 0; NSGetSizeAndAlignment(t, &sz, NULL);
                unsigned char buf[16]; memset(buf, 0, sizeof(buf));
                memcpy(buf, &v, MIN(sz, sizeof(buf)));
                [inv setArgument:buf atIndex:i];
            } else if (hasVal && t[0] == 'd') {
                double v = [a doubleValue]; [inv setArgument:&v atIndex:i];
            } else if (hasVal && t[0] == 'f') {
                float v = [a floatValue]; [inv setArgument:&v atIndex:i];
            } else {
                // 猜不到的（或没给值的）→ 零填充
                NSUInteger sz = 0; NSGetSizeAndAlignment(t, &sz, NULL);
                if (sz > 0 && sz <= 16) {
                    unsigned char buf[16]; memset(buf, 0, sizeof(buf));
                    [inv setArgument:buf atIndex:i];
                }
            }
        }
        [inv invoke];

        const char *rt = sig.methodReturnType;
        if (rt && (rt[0] == '@' || rt[0] == '#') && sig.methodReturnLength <= sizeof(void*)) {
            id ret = nil; [inv getReturnValue:&ret]; return ret;
        }
    } @catch (NSException *e) {
        MVLog(@"[direct] 调用 -%@ 抛异常：%@", selName, e.reason);
    }
    return nil;
}

// TTS 喂完后到 StopRecord 之间的余量（秒）。只为让最后一块 buffer 落地，
// 太长会白录一段静音、拖长发送时间。参考实现 v23 从 1.2s 收到 0.3s；
// 实测最后一块在 100ms 内必落地，这里取 0.25s。
static const double kMVPostFeedWait = 0.25;

// ★ 2.8.15：在对象图里深搜某个类的实例（用于 QQ 主动找 PttRecordOperator）。
//   仅下钻时拦截 Foundation/UIKit/CoreFoundation 等巨型系统图，避免爆栈/卡死；
//   根对象（如聊天 VC）允许继续下钻，命中目标类即返回（UI/系统类也不漏）。
static BOOL MVClassMatches(Class c, NSArray *names);
static id MVFindQQInstanceOfClasses(id obj, NSArray<NSString*>*clsNames, int depth, int *guard) {
    if (!obj || !clsNames.count) return nil;
    if ((*guard)++ > 12000) return nil;
    if (depth > 6) return nil;
    Class root = object_getClass(obj);
    if (MVClassMatches(root, clsNames)) return obj;
    if (depth > 0) {
        NSString *cn = NSStringFromClass(root) ?: @"";
        if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"UI"] || [cn hasPrefix:@"CA"] ||
            [cn hasPrefix:@"_"] || [cn hasPrefix:@"CF"] || [cn hasPrefix:@"Swift"] ||
            [cn hasPrefix:@"WK"] || [cn hasPrefix:@"__"]) return nil;
    }
    @try {
        Class c = root; int lvl = 0;
        while (c && lvl < 6) {
            unsigned int cnt = 0;
            Ivar *ivs = class_copyIvarList(c, &cnt);
            if (ivs) {
                for (unsigned int i = 0; i < cnt; i++) {
                    const char *te = ivar_getTypeEncoding(ivs[i]);
                    if (!te || te[0] != '@') continue;
                    id v = nil;
                    @try { v = object_getIvar(obj, ivs[i]); } @catch (NSException *e) { v = nil; }
                    if (!v) continue;
                    NSString *vn = NSStringFromClass(object_getClass(v)) ?: @"";
                    if ([vn hasPrefix:@"NS"] || [vn hasPrefix:@"UI"] || [vn hasPrefix:@"CA"] ||
                        [vn hasPrefix:@"_"] || [vn hasPrefix:@"CF"] || [vn hasPrefix:@"Swift"]) continue;
                    id r = MVFindQQInstanceOfClasses(v, clsNames, depth + 1, guard);
                    if (r) { free(ivs); return r; }
                }
                free(ivs);
            }
            c = class_getSuperclass(c); lvl++;
        }
    } @catch (NSException *e) { }
    return nil;
}

// ★ 2.8.16：递归遍历 UIView 子树找 QQPttRecordBtn（按钮在视图层级里，不在 ivar 图里，
//   所以 MVFindQQInstanceOfClasses 遍历不到，这里专门走 subviews）。
static id MVFindQQRecordButtonInView(UIView *root, NSArray<NSString*>*names) {
    if (!root) return nil;
    if (MVClassMatches(object_getClass(root), names)) return root;
    for (UIView *sub in root.subviews) {
        id r = MVFindQQRecordButtonInView(sub, names);
        if (r) return r;
    }
    return nil;
}

@implementation MyVoiceDirectSend

+ (instancetype)shared {
    static id s; static dispatch_once_t t; dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

#pragma mark - 类名候选（版本自适应）

+ (NSArray<NSString*>*)recordControllerNames {
    return @[@"RecordController", @"VoiceRecordController", @"AudioRecordController",
             @"MMAudioRecordController", @"ChatRecordController"];
}
+ (NSArray<NSString*>*)audioSenderNames {
    return @[@"AudioSender", @"VoiceSender", @"BaseAudioSender", @"MMAudioSender"];
}

static BOOL MVClassMatches(Class c, NSArray *names) {
    int d = 0;
    while (c && d++ < 6) {
        NSString *n = NSStringFromClass(c);
        if (n && [names containsObject:n]) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}

// 在对象自身 + 父类的 ivar 里找「类名命中 names」的对象（只下钻"名字看着相关"的字段）
static id MVFindInGraph(id obj, NSArray *names, int depth, int *guard) {
    if (!obj || depth > 2 || !guard) return nil;
    if ((*guard)++ > 3000) return nil;

    Class root = object_getClass(obj);
    NSString *cn = NSStringFromClass(root) ?: @"";
    if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"UI"] || [cn hasPrefix:@"CA"] ||
        [cn hasPrefix:@"_"] || [cn hasPrefix:@"CF"] || [cn hasPrefix:@"Swift"]) return nil;

    @try {
        Class c = root; int lvl = 0;
        while (c && lvl < 6) {
            unsigned int cnt = 0;
            Ivar *ivs = class_copyIvarList(c, &cnt);
            if (ivs) {
                for (unsigned int i = 0; i < cnt; i++) {
                    const char *te = ivar_getTypeEncoding(ivs[i]);
                    if (!te || te[0] != '@') continue;      // 只看对象型字段
                    const char *nm = ivar_getName(ivs[i]);
                    id v = nil;
                    @try { v = object_getIvar(obj, ivs[i]); } @catch (NSException *e) { v = nil; }
                    if (!v) continue;
                    if (MVClassMatches(object_getClass(v), names)) { free(ivs); return v; }

                    if (depth < 2) {
                        NSString *ivn = nm ? [NSString stringWithUTF8String:nm] : @"";
                        BOOL interesting =
                            ([ivn rangeOfString:@"record" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [ivn rangeOfString:@"audio"  options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [ivn rangeOfString:@"sender" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [ivn rangeOfString:@"voice"  options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [ivn rangeOfString:@"delegate" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [ivn rangeOfString:@"logic" options:NSCaseInsensitiveSearch].location != NSNotFound);
                        if (interesting) {
                            id r = MVFindInGraph(v, names, depth + 1, guard);
                            if (r) { free(ivs); return r; }
                        }
                    }
                }
                free(ivs);
            }
            c = class_getSuperclass(c); lvl++;
        }
    } @catch (NSException *e) { }
    return nil;
}

// 从聊天页（及其 m_delegate / 逻辑控制器）里捞微信内部录音相关实例
+ (id)locate:(NSArray<NSString*>*)names {
    // ① 聊天页自身 + 它的逻辑控制器
    NSArray *vcList = nil;
    @try { vcList = [MyVoiceResolver allViewControllers]; } @catch (NSException *e) { vcList = nil; }
    for (UIViewController *vc in vcList) {
        @try {
            // ★ 2.3.1：先严格（MsgContent）后模糊（ChatViewController 等）——
            //   新版微信改了聊天页类名时也能定位到 RecordController/AudioSender
            BOOL strictHit = [MyVoiceResolver isChatVC:vc];
            BOOL relaxedHit = !strictHit && [MyVoiceResolver isChatVCRelaxed:vc];
            if (!strictHit && !relaxedHit) continue;
            int g = 0;
            id r = MVFindInGraph(vc, names, 0, &g);
            if (r) return r;
            id dg = [MyVoiceResolver valueForIvars:vc names:@[@"m_delegate", @"m_logicController",
                                                              @"m_oLogicController", @"logicController",
                                                              @"m_delegateController"]];
            if (dg) {
                int g2 = 0;
                r = MVFindInGraph(dg, names, 0, &g2);
                if (r) return r;
                // 有些版本直接挂在具名字段上（ivar 名不含 record/audio 关键字时靠这条兜住）
                for (NSString *k in @[@"m_recordController", @"recordController", @"m_oRecordController",
                                      @"m_audioSender", @"audioSender", @"m_recordSender"]) {
                    id v = [MyVoiceResolver valueForIvars:dg names:@[k]];
                    if (v && MVClassMatches(object_getClass(v), names)) return v;
                }
            }
        } @catch (NSException *e) { }
    }
    // ② 服务容器兜底（部分版本 RecordController 是 service）
    for (NSString *n in names) {
        id s = MVService(n);
        if (s && MVClassMatches(object_getClass(s), names)) return s;
    }
    return nil;
}

static id gRC = nil;      // RecordController
static id gAS = nil;      // AudioSender

+ (id)recordController {
    if (gRC) return gRC;
    gRC = [self locate:[self recordControllerNames]];
    if (gRC) MVLog(@"[direct] 找到 RecordController = %@", NSStringFromClass(object_getClass(gRC)));
    return gRC;
}

+ (id)audioSender {
    if (gAS) return gAS;
    id rc = [self recordController];       // 优先从 RecordController 内部拿配套 sender
    if (rc) {
        int g = 0;
        gAS = MVFindInGraph(rc, [self audioSenderNames], 0, &g);
        if (!gAS) {
            for (NSString *k in @[@"m_audioSender", @"audioSender", @"m_sender", @"sender",
                                  @"m_recordSender", @"m_oAudioSender"]) {
                id v = [MyVoiceResolver valueForIvars:rc names:@[k]];
                if (v && MVClassMatches(object_getClass(v), [self audioSenderNames])) { gAS = v; break; }
            }
        }
    }
    if (!gAS) gAS = [self locate:[self audioSenderNames]];
    if (gAS) MVLog(@"[direct] 找到 AudioSender = %@", NSStringFromClass(object_getClass(gAS)));
    return gAS;
}

#pragma mark - 可用性 / 诊断

+ (BOOL)qqAvailable {
    // ★ 2.6.0：QQ 全自动直发恢复。frida spawn 全链路实锤（按住一次的完整序列）：
    //   QQPttRecordBtn touchesBegan → NTAIOPttRecordOperator -didTriggeredRecord（开始，
    //   由此创建 QQPttRecorder/AudioQueue=劫持点）→ touchesEnded → QQPttRecorder
    //   -stopRecord（结束并发送）。直发 = 复用 operator 调 didTriggeredRecord 开始，
    //   轮询 TTS 喂完后对新 QQPttRecorder 调 stopRecord。
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid rangeOfString:@"tencent.mqq"].location != NSNotFound &&
        NSClassFromString(@"QQPttRecordOperator") != nil) {
        [self installQQHooksIfNeeded];
        return YES;
    }
    return NO;
}

// ---- QQ 直发扣留（★ 2.6.0：operator = 开始入口；recorder = 每次新建，结束时 stop）----
// frida spawn 全链路实测：touchesBegan → operator didTriggeredRecord →
//   QQPttRecorder initRecorder/createRecorder → AudioQueue；touchesEnded → stopRecord。
static id  g_mvQQOperator = nil;   // 最近一次按住的聊天操作器（强引用，含聊天上下文）
static id  g_mvQQRecorder = nil;   // 最近一次录音的 QQPttRecorder（每次录音新建）
static IMP g_mvOrigQQDidTrig = NULL;
static IMP g_mvOrigQQCreateRec = NULL;
static IMP g_mvOrigQQRecStart = NULL;   // ★ 2.8.22：recorder -startRecordAsync:completion: 原始实现
static BOOL g_mvQQOpHookInstalled  = NO;   // ★ 2.8.20：operator 钩独立标志（类可能晚加载）
static BOOL g_mvQQRecHookInstalled = NO;   // ★ 2.8.20：recorder createRecorder 钩独立标志
static BOOL g_mvQQRecStartHookInstalled = NO;   // ★ 2.8.22：recorder startRecordAsync:completion: 钩独立标志

// ★ 2.8.19：直接捕获 QQPushToTalkView 实例（不再递归遍历 vc.view.subviews —— 该遍历会在
//   QQ 切换语音模式时碰到正在释放的视图，for...in 拿到悬空数组 → EXC_BAD_ACCESS 闪退）。
//   与 g_mvQQOperator/g_mvQQRecorder 同思路：在视图出现/开始录音时由钩子扣留 self。
static id  g_mvQQPushToTalkView = nil;   // 当前语音模式下的「按住说话」视图（UIKit 持有，不 CFRetain）
static IMP g_mvOrigQQPTVDidMoveToWindow = NULL;
static IMP g_mvOrigQQPTVStartRecord = NULL;
static BOOL g_mvQQPTVHookInstalled = NO;
static BOOL g_mvQQRetryScheduled   = NO;   // ★ 2.8.20：类加载重试链只挂一次

static void MVQQPTVDidMoveToWindowHook(id self, SEL _cmd, UIWindow *window) {
    @synchronized([MyVoiceDirectSend class]) { g_mvQQPushToTalkView = window ? self : nil; }
    if (window) MVLog(@"[direct] 已捕获 QQPushToTalkView %p（didMoveToWindow）", self);
    if (g_mvOrigQQPTVDidMoveToWindow)
        ((void(*)(id, SEL, UIWindow*))g_mvOrigQQPTVDidMoveToWindow)(self, _cmd, window);
}
static void MVQQPTVStartRecordHook(id self, SEL _cmd) {
    @synchronized([MyVoiceDirectSend class]) { g_mvQQPushToTalkView = self; }
    MVLog(@"[direct] 已捕获 QQPushToTalkView %p（startRecordAsync）", self);
    if (g_mvOrigQQPTVStartRecord)
        ((void(*)(id, SEL))g_mvOrigQQPTVStartRecord)(self, _cmd);
}
// 懒安装：QQPushToTalkView 类可能到进入语音模式才加载，故每次查找时重试（类不存在则跳过）
static void ensureQQPTVHook(void) {
    if (g_mvQQPTVHookInstalled) return;
    Class vcls = NSClassFromString(@"QQPushToTalkView");
    if (!vcls) return;
    MSHookMessageEx(vcls, @selector(didMoveToWindow), (IMP)MVQQPTVDidMoveToWindowHook, (IMP *)&g_mvOrigQQPTVDidMoveToWindow);
    MSHookMessageEx(vcls, @selector(startRecordAsync), (IMP)MVQQPTVStartRecordHook, (IMP *)&g_mvOrigQQPTVStartRecord);
    g_mvQQPTVHookInstalled = YES;
    MVLog(@"[direct] QQ QQPushToTalkView 钩子已安装");
}

static void MVQQOperatorDidTrigHook(id self, SEL _cmd, id arg) {
    @synchronized([MyVoiceDirectSend class]) {
        if (g_mvQQOperator != self) {
            if (g_mvQQOperator) CFRelease((__bridge CFTypeRef)g_mvQQOperator);
            g_mvQQOperator = self;
            CFRetain((__bridge CFTypeRef)self);
            MVLog(@"[direct] 已扣留聊天页 PttRecordOperator %p（当前聊天已激活）", self);
        }
    }
    if (g_mvOrigQQDidTrig)
        ((void(*)(id, SEL, id))g_mvOrigQQDidTrig)(self, _cmd, arg);
}

static id MVQQCreateRecorderHook(id self, SEL _cmd) {
    id rec = ((id(*)(id, SEL))g_mvOrigQQCreateRec)(self, _cmd);
    if (rec) {
        @synchronized([MyVoiceDirectSend class]) {
            // ★ 2.8.23：startRecordAsync:completion: 先扣的是真正在录音的 recorder；
            //   createRecorder 可能返回内部新建对象，仅在尚未扣留时才设，避免覆盖成错误实例。
            if (g_mvQQRecorder == nil) {
                g_mvQQRecorder = rec;
                CFRetain((__bridge CFTypeRef)rec);
                MVLog(@"[direct] 已扣留新 QQPttRecorder %p", rec);
            }
        }
    }
    return rec;
}

// ★ 2.8.22：录音真正开始时（不论走 +createRecorder 还是 alloc/init 路径），recorder 必然调用
//   -startRecordAsync:completion:。在此扣留 self，确保「停止」阶段 100% 拿得到当前 recorder 实例
//   —— 2.8.15~2.8.21 全自动模式「一直录、停不下来」的根因正是：自动走 startRecordAsync 入口，
//   recorder 创建路径没命中 createRecorder 钩 → g_mvQQRecorder 为 nil → 停止时直接 return、啥也没调。
static void MVQQRecorderStartHook(id self, SEL _cmd, id arg1, id arg2) {
    @synchronized([MyVoiceDirectSend class]) {
        if (g_mvQQRecorder != self) {
            if (g_mvQQRecorder) CFRelease((__bridge CFTypeRef)g_mvQQRecorder);
            g_mvQQRecorder = self;
            CFRetain((__bridge CFTypeRef)self);
            MVLog(@"[direct] 已扣留 QQPttRecorder %p（startRecordAsync:completion:）", self);
        }
    }
    ((void(*)(id, SEL, id, id))g_mvOrigQQRecStart)(self, _cmd, arg1, arg2);
}

+ (void)installQQHooks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class op = NSClassFromString(@"QQPttRecordOperator");
        if (op) {
            MSHookMessageEx(op, @selector(didStartRecordAsync:), (IMP)MVQQOperatorDidTrigHook, (IMP *)&g_mvOrigQQDidTrig);
            MVLog(@"[direct] QQ didStartRecordAsync: 钩子已安装");
        }
        Class rec = NSClassFromString(@"QQPttRecorder");
        if (rec) {
            MSHookMessageEx(rec, @selector(createRecorder), (IMP)MVQQCreateRecorderHook, (IMP *)&g_mvOrigQQCreateRec);
            MVLog(@"[direct] QQ QQPttRecorder createRecorder 钩子已安装");
        }
    });
}

// ★ 2.8.20：把「能装上的钩子都装上」（类可能到用户首次进语音模式才被 dyld 加载，
//   故每次调用都重试，按各自标志幂等）。在 tweak 启动期就反复调本函数，
//   确保用户「切到语音模式 → didMoveToWindow 触发」时钩子早已在位、能扣留视图实例——
//   这是 2.8.15~2.8.19 永远退回手动的根因（钩子在点发送时才装，窗口早已出现，捕获恒为 nil）。
static void MVQQTryInstallHooks(void) {
    @synchronized([MyVoiceDirectSend class]) {
        Class op = NSClassFromString(@"QQPttRecordOperator");
        if (op && !g_mvQQOpHookInstalled) {
            MSHookMessageEx(op, @selector(didStartRecordAsync:), (IMP)MVQQOperatorDidTrigHook, (IMP *)&g_mvOrigQQDidTrig);
            g_mvQQOpHookInstalled = YES;
            MVLog(@"[direct] QQ didStartRecordAsync: 钩子已安装");
        }
        Class rec = NSClassFromString(@"QQPttRecorder");
        if (rec && !g_mvQQRecHookInstalled) {
            MSHookMessageEx(rec, @selector(createRecorder), (IMP)MVQQCreateRecorderHook, (IMP *)&g_mvOrigQQCreateRec);
            g_mvQQRecHookInstalled = YES;
            MVLog(@"[direct] QQ QQPttRecorder createRecorder 钩子已安装");
        }
        // ★ 2.8.22：补 startRecordAsync:completion: 钩，覆盖所有 recorder 创建路径
        if (rec && !g_mvQQRecStartHookInstalled) {
            MSHookMessageEx(rec, @selector(startRecordAsync:completion:), (IMP)MVQQRecorderStartHook, (IMP *)&g_mvOrigQQRecStart);
            g_mvQQRecStartHookInstalled = YES;
            MVLog(@"[direct] QQ QQPttRecorder startRecordAsync:completion: 钩子已安装");
        }
        Class vcls = NSClassFromString(@"QQPushToTalkView");
        if (vcls && !g_mvQQPTVHookInstalled) {
            MSHookMessageEx(vcls, @selector(didMoveToWindow), (IMP)MVQQPTVDidMoveToWindowHook, (IMP *)&g_mvOrigQQPTVDidMoveToWindow);
            MSHookMessageEx(vcls, @selector(startRecordAsync), (IMP)MVQQPTVStartRecordHook, (IMP *)&g_mvOrigQQPTVStartRecord);
            g_mvQQPTVHookInstalled = YES;
            MVLog(@"[direct] QQ QQPushToTalkView 钩子已安装");
        }
    }
}

// ★ 2.8.20：tweak 启动即挂重试链（最多 ~12s），类一加载就装上；非 QQ 直接返回。
+ (void)installQQHooksIfNeeded {
    if (!mvDiagIsQQ()) return;
    MVQQTryInstallHooks();
    if (g_mvQQOpHookInstalled && g_mvQQRecHookInstalled && g_mvQQPTVHookInstalled) return;
    if (g_mvQQRetryScheduled) return;
    g_mvQQRetryScheduled = YES;
    for (int i = 0; i < 24; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 * (i + 1)) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ MVQQTryInstallHooks(); });
    }
}

+ (id)stashedQQOperator { @synchronized([MyVoiceDirectSend class]) { return g_mvQQOperator; } }
// ★ 2.6.3：手动按住模式的「自动松手」监视器。
//   用户按住说话 → QQ 创建新 QQPttRecorder（createRecorder 钩子扣留）→ 队列被喂 TTS；
//   TTS 喂完（fedDone）且已按住 ≥1.3s（防「太短」丢弃）→ 自动 stopRecord：
//   等效于用户在 TTS 结束瞬间松手 —— 消息长度 = TTS 长度，用户无需数秒。
+ (void)beginQQAutoStopWatch {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];
        MVLog(@"[autoStop] 监视器启动：TTS 喂完后将自动停止并发送");
        while (YES) {
            @autoreleasepool {
                if (![MyVoiceRecorder isArmed]) { MVLog(@"[autoStop] 装填已解除，监视器退出"); return; }
                NSTimeInterval el = [[NSDate date] timeIntervalSince1970] - t0;
                if (el > 30) { MVLog(@"[autoStop] 30s 超时退出（未满足停止条件）"); return; }
                if ([MyVoiceRecorder fedDone] && el >= 1.3) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        id rec = [MyVoiceDirectSend stashedQQRecorder];
                        id op  = [MyVoiceDirectSend stashedQQOperator];
                        if (rec) [MyVoiceDirectSend mvQQSendRecorder:rec];
                        if (op)  MVInvoke(op, @"onRecordEnd:send:", @[[NSNull null], @YES]);
                        if (rec || op) {
                            [[MyVoiceManager shared] toast:@"✅ 语音已发出，可以松手了"];
                            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
                            if (@available(iOS 10.0, *)) {
                                UINotificationFeedbackGenerator *hg = [[UINotificationFeedbackGenerator alloc] init];
                                [hg prepare];
                                [hg notificationOccurred:UINotificationFeedbackTypeSuccess];
                            }
                            MVLog(@"[autoStop] ✅ TTS 已喂完，自动停止并发送 + 震动（已发出可松手）");
                            [MyVoiceRecorder resetAfterSend:2.0];
                        }
                    });
                    return;
                }
                usleep(100 * 1000);
            }
        }
    });
}
+ (id)stashedQQRecorder { @synchronized([MyVoiceDirectSend class]) { return g_mvQQRecorder; } }

// ---- ★ 2.8.18：QQ 全自动直发（点「合成语音」无需手动按住）----
//   实机 frida 全链路确认的真链路（2.8.15~2.8.17 失败根因：① 键盘模式硬找 QQPttRecordBtn
//   找不到 → 永远退回手动；② 旧版用 stopRecord 收尾，但真链发送方法是 sendRecordData）。
//     开始：QQPushToTalkView -startRecordAsync → QQPttRecordOperator -didStartRecordAsync:
//            → NTAIOChat.NTAIOPttRecordOperator -didTriggeredRecord（钩子扣留 Operator）
//            → QQPttRecorder +createRecorder（钩子扣留 Recorder）→ AudioQueue 被 MyVoiceRecorder 劫持喂入 TTS
//     发送：QQPttRecorder -sendRecordData（无参）→ QQPttRecordOperator -onRecordEnd:send:(send=YES)
//            → NTAIOChat.NTAIOPttRecordOperator -sendAudioWithAudioModel:completion:（真发）
//   故「自动发送」= 直接调 startRecordAsync 开始 + 喂完 TTS 后调 sendRecordData 发送，零手动。
+ (id)mvQQFindPushToTalkView {
    [self installQQHooksIfNeeded];   // ★ 2.8.20：确保钩子已装（类可能刚加载）
    @synchronized([MyVoiceDirectSend class]) {
        id v = g_mvQQPushToTalkView;
        if (v && [v isKindOfClass:NSClassFromString(@"QQPushToTalkView")] && [v window] != nil) {
            MVLog(@"[direct] QQ 自动：复用已捕获且在窗口的 QQPushToTalkView %p", v);
            return v;
        }
    }
    // ★ 2.8.20：钩子可能在视图出现前没装上（极端情况）→ 实时遍历当前聊天页视图树找
    //   QQPushToTalkView，避免「永远退回手动」。遍历只读类名、不碰视图状态，安全。
    Class vcls = NSClassFromString(@"QQPushToTalkView");
    if (vcls) {
        @try {
            UIViewController *vc = [MyVoiceResolver currentChatVC];
            if (vc && vc.view) {
                id found = MVFindQQRecordButtonInView(vc.view, @[NSStringFromClass(vcls)]);
                if (found) {
                    @synchronized([MyVoiceDirectSend class]) { g_mvQQPushToTalkView = found; }
                    MVLog(@"[direct] QQ 自动：实时遍历找到 QQPushToTalkView %p", found);
                    return found;
                }
            }
        } @catch (NSException *e) { MVLog(@"[direct] QQ 自动：遍历视图树异常 %@", e.reason); }
    }
    MVLog(@"[direct] QQ 自动：未捕获到 QQPushToTalkView（需先处于语音模式）");
    return nil;
}

// 切到语音模式：★ 2.8.19 起不再递归遍历视图树（会闪退），改为返回 NO 由上层安全退回手动。
//   后续若需自动切换，应改用「捕获输入栏按钮」钩子，而非遍历 vc.view.subviews。
+ (BOOL)mvQQSwitchToVoiceMode {
    MVLog(@"[direct] QQ 自动：跳过自动切语音模式（避免遍历视图树闪退），请先处于语音模式");
    return NO;
}

// 自动开始录音：直接调已捕获的 QQPushToTalkView.startRecordAsync（真链路入口，零手动）。
// ★ 2.8.19：不再递归遍历视图树 / 不再阻塞主线程 usleep / 不再合成触摸按钮
//   （那套在 QQ 切换语音模式时会遍历到正在释放的视图 → 闪退）。拿不到捕获视图就返回 nil，
//   由上层 sendArmedTo 安全退回「请手动按住」提示，绝不崩溃。
+ (id)qqAutoStartRecord:(BOOL*)outStarted {
    if (outStarted) *outStarted = NO;
    id view = [self mvQQFindPushToTalkView];
    if (!view) {
        MVLog(@"[direct] QQ 自动：无可用 QQPushToTalkView —— 退回手动按住");
        return nil;
    }
    [MyVoiceRecorder beginQueueBinding];
    SEL sel = NSSelectorFromString(@"startRecordAsync");
    if ([view respondsToSelector:sel]) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [view performSelector:sel];
            #pragma clang diagnostic pop
            id op = [MyVoiceDirectSend stashedQQOperator];
            if (!op) { usleep(50 * 1000); op = [MyVoiceDirectSend stashedQQOperator]; }
            if (op) { if (outStarted) *outStarted = YES; MVLog(@"[direct] QQ 自动：startRecordAsync 已触发 Operator=%p", op); return op; }
        } @catch (NSException *e) { MVLog(@"[direct] QQ 自动：startRecordAsync 异常 %@", e.reason); }
    }
    MVLog(@"[direct] QQ 自动：startRecordAsync 未生效 —— 退回手动按住");
    return nil;
}

// 结束并发送：真链是 QQPttRecorder -sendRecordData（无参）。退化 stopRecord。
+ (void)mvQQSendRecorder:(id)rec {
    if (!rec) return;
    SEL sel = NSSelectorFromString(@"sendRecordData");
    if ([rec respondsToSelector:sel]) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [rec performSelector:sel];
            #pragma clang diagnostic pop
            MVLog(@"[direct] QQ 自动：已调 sendRecordData 发送");
            return;
        } @catch (NSException *e) { MVLog(@"[direct] QQ 自动：sendRecordData 异常，退化 stopRecord：%@", e.reason); }
    }
    MVInvoke(rec, @"stopRecord", nil);
}

+ (id)qqFindRecordButton {
    UIViewController *vc = nil;
    @try { vc = [MyVoiceResolver currentChatVC]; } @catch (NSException *e) { vc = nil; }
    if (!vc || !vc.view) { MVLog(@"[direct] QQ 自动：未找到当前聊天页 VC"); return nil; }
    Class btnCls = NSClassFromString(@"QQPttRecordBtn");
    NSArray *btnNames = btnCls ? @[NSStringFromClass(btnCls)] : @[];
    if (!btnNames.count) { MVLog(@"[direct] QQ 自动：未找到 QQPttRecordBtn 类"); return nil; }
    id found = MVFindQQRecordButtonInView(vc.view, btnNames);
    if (found) {
        UIView *fv = (UIView *)found;
        MVLog(@"[direct] QQ 自动：找到录音按钮 %@（isUIControl=%@, gestures=%lu）",
              NSStringFromClass(object_getClass(found)),
              [found isKindOfClass:[UIControl class]] ? @"Y" : @"N",
              (unsigned long)fv.gestureRecognizers.count);
        for (UIGestureRecognizer *g in fv.gestureRecognizers)
            MVLog(@"[mvdiag]   按钮手势：%@", mvDiagGRInfo(g));
    } else {
        MVLog(@"[direct] QQ 自动：当前聊天页视图树内未找到 QQPttRecordBtn —— Dump 真实视图树");
        MVDebugDumpInputTree(vc.view);
    }
    return found;
}

// 合成一个落在指定视图上的触摸（KVC 直写 UITouch 私有 ivar；不进系统事件分发，直接喂给视图的
// touchesBegan:，从而触发按钮自身（或 UIControl）的按下逻辑，等价于手指按下）。
+ (UITouch*)mvSyntheticTouchOnView:(UIView*)view phase:(UITouchPhase)phase {
    UIWindow *win = view.window;
    if (!win) @try { win = [MyVoiceResolver anyWindow]; } @catch (NSException *e) { win = nil; }
    UITouch *t = [[UITouch alloc] init];
    [t setValue:view forKey:@"view"];
    if (win) [t setValue:win forKey:@"window"];
    [t setValue:@(phase) forKey:@"phase"];
    [t setValue:@(1) forKey:@"tapCount"];
    CGPoint c = CGPointMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0);
    CGPoint inWin = (win && [view respondsToSelector:@selector(convertPoint:toView:)])
                   ? [view convertPoint:c toView:win] : c;
    [t setValue:[NSValue valueWithCGPoint:inWin] forKey:@"_locationInWindow"];
    [t setValue:[NSValue valueWithCGPoint:inWin] forKey:@"_previousLocationInWindow"];
    [t setValue:[NSNumber numberWithDouble:[[NSProcessInfo processInfo] systemUptime]]
          forKey:@"timestamp"];
    return t;
}

+ (id)qqAutoPressRecordButton:(BOOL*)outStarted {
    if (outStarted) *outStarted = NO;
    @synchronized([MyVoiceDirectSend class]) {
        if (g_mvQQOperator) { MVLog(@"[direct] QQ 自动：复用已扣留 Operator"); return g_mvQQOperator; }
    }
    UIView *btn = [self qqFindRecordButton];
    if (!btn) return nil;
    // ★ 必须在「模拟按下」之前开喂入会话：recorder 的 AudioQueue 在 touchesBegan 内创建，
    //   只有先 beginQueueBinding，该队列才会被登记进本次喂入集合（见 MyVoiceRecorder）。
    [MyVoiceRecorder beginQueueBinding];
    // ① 直接把 touchesBegan 喂给按钮（QQPttRecordBtn 重写该方法触发 didTriggeredRecord）
    UITouch *t = [self mvSyntheticTouchOnView:btn phase:UITouchPhaseBegan];
    UIEvent *e = [[UIEvent alloc] init];
    [e setValue:[NSSet setWithObject:t] forKey:@"_touches"];
    @try { [btn touchesBegan:[NSSet setWithObject:t] withEvent:e]; }
    @catch (NSException *ex) { MVLog(@"[direct] QQ 自动：touchesBegan 抛异常 %@", ex.reason); }
    id op = [MyVoiceDirectSend stashedQQOperator];
    if (op) { if (outStarted) *outStarted = YES; return op; }
    // ② 兜底：若按钮是 UIControl 且用 control-event 触发录制，补一发 TouchDown
    if ([btn isKindOfClass:[UIControl class]]) {
        @try { [(UIControl*)btn sendActionsForControlEvents:UIControlEventTouchDown]; }
        @catch (NSException *ex) { MVLog(@"[direct] QQ 自动：sendActions 抛异常 %@", ex.reason); }
        op = [MyVoiceDirectSend stashedQQOperator];
        if (op) { if (outStarted) *outStarted = YES; return op; }
    }
    MVLog(@"[direct] QQ 自动：模拟按下仍未创建 Operator（该 QQ 版本可能不认合成触摸）");
    @try {   // 收尾：把这次未生效的触摸取消，避免按钮内部状态悬挂
        [t setValue:@(UITouchPhaseCancelled) forKey:@"phase"];
        [btn touchesCancelled:[NSSet setWithObject:t] withEvent:e];
    } @catch (NSException *ex) { }
    return nil;
}

+ (BOOL)available {
    if ([self qqAvailable]) return YES;
    if ([NSThread isMainThread]) return ([self recordController] != nil || [self audioSender] != nil);
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = ([self recordController] != nil || [self audioSender] != nil);
    });
    return ok;
}

+ (NSString*)diag {
    NSMutableString *s = [NSMutableString string];
    id rc = [self recordController], as = [self audioSender];
    [s appendFormat:@"RecordController：%@\n", rc ? NSStringFromClass(object_getClass(rc)) : @"未找到 ❌"];
    if (rc) {
        [s appendFormat:@"  可开录音：%@\n", [rc respondsToSelector:NSSelectorFromString(@"StartRecordingFromUsr:ToUsr:UserInfo:")] ? @"是 ✅" : @"否"];
        [s appendFormat:@"  可停录音：%@\n", [rc respondsToSelector:NSSelectorFromString(@"StopRecordingInternal:")] ? @"是 ✅" : @"否"];
    }
    [s appendFormat:@"AudioSender：%@\n", as ? NSStringFromClass(object_getClass(as)) : @"未找到"];
    if (as) {
        [s appendFormat:@"  StartRecordFrom:ToUser:UserInfo: = %@\n",
            [as respondsToSelector:NSSelectorFromString(@"StartRecordFrom:ToUser:UserInfo:")] ? @"有 ✅" : @"无"];
        [s appendFormat:@"  StopRecord = %@\n",
            [as respondsToSelector:NSSelectorFromString(@"StopRecord")] ? @"有 ✅" : @"无"];
    }
    return s;
}

#pragma mark - 无界面直发

- (void)sendArmedTo:(NSString*)talker
           duration:(double)seconds
         completion:(void(^)(BOOL ok, NSString *reason))completion {

    void (^fin)(BOOL, NSString*) = ^(BOOL ok, NSString *r){
        if (completion) MVOnMain(^{ completion(ok, r); });
    };
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendArmedTo:talker duration:seconds completion:completion];
        });
        return;
    }

    // ★ 2.5.1 QQ 模式不需要 wxid（发给谁由「当前聊天页」决定，NT 架构拿不到也无妨）。
    BOOL qqMode = [MyVoiceDirectSend qqAvailable];
    if (!qqMode) {
        // ★ 2.3.0：上游 wxid 缺失时最后再解析一次（用户此刻多半就在聊天页里，能拿到）。
        //   仍失败就干净退出 —— 此时录音还没启动，不会残留半开的录音会话，更不会往
        //   空会话里录（StartRecordingFromUsr: 传空 ToUsr 行为不可知，必须避免）。
        if (!talker.length) talker = [MyVoiceResolver currentTalker];
        if (!talker.length) {
            MVLog(@"[direct] ❌ 无法确定会话 ID（wxid），放弃直发。VC 树：\n%@",
                  [MyVoiceResolver vcTreeDump]);
            fin(NO, @"未识别到会话 ID（请停留在聊天页里再试）");
            return;
        }
    }

    NSString *me = [MyVoiceResolver selfWxid] ?: @"";
    id rc = [MyVoiceDirectSend recordController];
    id as = [MyVoiceDirectSend audioSender];

    // ★ 2.8.16：开喂入会话必须【早于】「模拟按下 / 调启动方法」—— recorder 的 AudioQueue
    //   在按下瞬间创建（见 qqAutoPressRecordButton），只有先 beginQueueBinding，它才会被
    //   登记进本次喂入集合，TTS 才能注入（否则 fedBytes 始终为 0 → 1.2s 超时退回手动）。
    [MyVoiceRecorder beginQueueBinding];

    // ---- 选启动入口：★ 2.5.1 QQ 走自己的 PttRecorderManager；微信优先 RecordController ----
    id target = nil; NSString *startSel = nil; id stopTarget = nil; BOOL stopIsSender = NO;
    BOOL qqAlreadyStarted = NO;   // ★ 2.8.16：自动模拟按下已触发 didTriggeredRecord，勿重复调

    if (qqMode) {
        // ★ 2.8.18：直接 startRecordAsync 开始（真链路入口，零手动）。
        //   随后 fedDone 后由 stopWith 调 sendRecordData 发送。开始绝不再调 didTriggeredRecord（会重复触发）。
        target = [MyVoiceDirectSend qqAutoStartRecord:&qqAlreadyStarted];
        if (!target) {
            MVLog(@"[direct] QQ：无法自动开始录音 —— 保持装填，等待手动按住");
            [MyVoiceDirectSend beginQQAutoStopWatch];
            fin(NO, @"语音已就绪：请现在按住「按住 说话」，松开即发出（2 分钟内有效）");
            return;
        }
        startSel = nil;   // 开始已由 qqAutoStartRecord 内的 startRecordAsync 完成，勿重复触发
        MVLog(@"[direct] QQ 模式：%@ PttRecordOperator %p，喂完 TTS 后对新 QQPttRecorder sendRecordData 发送",
              qqAlreadyStarted ? @"startRecordAsync 创建" : @"复用", target);
    }

    if (qqMode) {
        // 入口已在上面选定
    } else if (rc && [rc respondsToSelector:NSSelectorFromString(@"StartRecordingFromUsr:ToUsr:UserInfo:")]) {
        target = rc; startSel = @"StartRecordingFromUsr:ToUsr:UserInfo:";
    } else if (as && [as respondsToSelector:NSSelectorFromString(@"StartRecordFrom:ToUser:UserInfo:")]) {
        target = as; startSel = @"StartRecordFrom:ToUser:UserInfo:";
    } else {
        MVLog(@"[direct] 无可用启动入口：\n%@", [MyVoiceDirectSend diag]);
        fin(NO, @"未找到微信内部录音入口");
        return;
    }

    // ---- 选停止入口：优先 AudioSender 的**无参** StopRecord（实测存在，零歧义） ----
    if (qqMode) {
        // QQ：stopRecord: 带一个 BOOL（按「发送」语义处理）；走专用停止分支
    } else if (as && [as respondsToSelector:NSSelectorFromString(@"StopRecord")]) {
        stopTarget = as; stopIsSender = YES;
    } else if (rc && [rc respondsToSelector:NSSelectorFromString(@"StopRecordingInternal:")]) {
        stopTarget = rc;
    } else if (rc && [rc respondsToSelector:NSSelectorFromString(@"StopRecordingAndSend")]) {
        stopTarget = rc;
    }

    MVLog(@"[direct] 直发开始：%@ -%@  (talker=%@, me=%@)",
          NSStringFromClass(object_getClass(target)), startSel, talker, me.length ? me : @"?");

    // ★ 2.2.5：先声明「接下来新建的录音队列才是本次替换目标」，再调启动方法。
    //   顺序不能反 —— 队列是启动方法内部创建的，先声明才能精确绑定；
    //   不绑定的话，同时存在的第二个输入队列也会被喂同一段 TTS → 两个声音/重音。
    MVInvoke(target, startSel, @[me, talker ?: @"", [NSNull null]]);

    // ---- 轮询：等「TTS 真正喂完」（fedDone）再松手 ----
    // 参考实现（TTSFloat v29）铁证：按【预估时长】定时 Stop 会截断数据 →
    // 微信一直在等完整音频 → 转圈/半截语音/好久不出来。
    // 这里改成等 fedDone（与真实喂入字节数挂钩，和采样率无关），再留一点余量（kMVPostFeedWait）让最后一块落地。
    double est = MAX(0.6, seconds);
    NSInteger capMs = (NSInteger)(MAX(8.0, est * 3.0 + 3.0) * 1000.0);   // 硬上限，防卡死
    __block NSInteger waited = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t){
        waited += 100;
        BOOL started = ([MyVoiceRecorder fedBytes] > 0);
        BOOL done    = [MyVoiceRecorder fedDone];

        if (!started && !done && waited >= 1200) {      // ≈1.2s 还没接管 → 判定失败
            [t invalidate];
            if (qqMode) {
                // ★ 2.6.2：QQ 自动触发不生效时【保留装填】—— 用户手动按住说话时
                //   队列照样加入会话被喂 TTS，松手即发出所选音色。
                MVLog(@"[direct] QQ 自动触发未生效 —— 保留装填，等待手动按住");
                [MyVoiceDirectSend beginQQAutoStopWatch];
                fin(NO, @"自动触发未生效：请手动按住「按住 说话」，松开即发出（2 分钟内有效）");
            } else {
                MVLog(@"[direct] ❌ 1.2s 内录音未被接管，取消直发（不会残留录音）");
                [MyVoiceRecorder cancelFeed];
                [MyVoiceDirectSend cancelWith:stopTarget sender:stopIsSender fallbackRC:rc];
                fin(NO, @"微信内部录音未按预期启动（版本接口可能不同）");
            }
            return;
        }
        // ★ 2.6.0：最短按住 1.3s（QQ 对 <1s 语音按太短丢弃）；TTS 喂完后自动补静音
        if ((done && waited >= 1300) || (started && waited >= capMs)) {
            [t invalidate];
            MVLog(@"[direct] ✅ TTS 已喂完（%ldms，%lu/%lu 字节）→ %.2fs 后停止并发送",
                  (long)waited, (unsigned long)[MyVoiceRecorder fedBytes],
                  (unsigned long)[MyVoiceRecorder totalBytes], kMVPostFeedWait);
            // 回调节奏报告：判断卡顿是否真由管线缺口造成（间隔 >> 块时长即为缺口）
            MVLog(@"[direct] %@", [MyVoiceRecorder cadenceReport]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMVPostFeedWait * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSString *used = [MyVoiceDirectSend stopWith:stopTarget sender:stopIsSender fallbackRC:rc qqMode:qqMode];
                MVLog(@"[direct] ✅ 已调用停止/发送：%@（微信自行完成 SILK 编码/入库/上传/气泡）", used);
                // 收尾：2.5s 后解除装填，避免残留状态把后续真实录音注成静音
                [MyVoiceRecorder resetAfterSend:2.5];
                fin(YES, nil);
            });
        }
    }];
}

// 停止并发送：优先无参 StopRecord（AudioSender）；退化到 RecordController 的停止方法
+ (NSString*)stopWith:(id)stopTarget sender:(BOOL)isSender fallbackRC:(id)rc qqMode:(BOOL)qqMode {
    if (qqMode) {
        // ★ 2.8.23：模拟用户松手 —— 调 QQPushToTalkView -touchEnd:(UITouch*)
        //   真机 frida 侦察确认（手动松手全栈）：QQPttRecordBtn.touchesEnded:withEvent:
        //   内部把单个 UITouch 交给 QQPushToTalkView.touchEnd:，这是「停止录音 + 发送」的
        //   【唯一真实入口】。之前调 sendRecordData / onRecordEnd:send: 是更底层的「发包」方法，
        //   它们要求 touchEnd: 先设好「已松手/录音结束」状态才能真正停 AudioQueue ——
        //   直接调它们等于绕过状态机，导致录音一直不停止、无法发送（2.8.20~2.8.22 翻车根因）。
        //   故自动发送 = 停止阶段也走和手动完全一致的 touchEnd:，QQ 内部正确停止并发送。
        @synchronized([MyVoiceDirectSend class]) {
            id view = g_mvQQPushToTalkView;
            // ★ 2.8.23：不检查 window —— 真机验证证明 touchEnd: 触停录音不依赖 window
            //   （window 为 nil 的残留视图调 touchEnd: 仍触发 stopRecord），检查反而会在
            //   录音中视图树短暂失效时漏调。只要视图实例在且响应 touchEnd: 就模拟松手。
            if (view && [view respondsToSelector:NSSelectorFromString(@"touchEnd:")]) {
                UITouch *t = [MyVoiceDirectSend mvSyntheticTouchOnView:view phase:UITouchPhaseEnded];
                @try {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [view performSelector:NSSelectorFromString(@"touchEnd:") withObject:t];
                    #pragma clang diagnostic pop
                    MVLog(@"[direct] QQ 停止：已模拟松手 touchEnd:（停止并发送）");
                    return @"QQ 模拟松手停止并发送";
                } @catch (NSException *e) {
                    MVLog(@"[direct] QQ touchEnd: 异常 %@，退化底层兜底", e.reason);
                }
            } else {
                MVLog(@"[direct] QQ 停止：无可用 PushToTalkView（view=%@）", view ? @"有" : @"nil");
            }
        }
        // 兜底丝（已知 sendRecordData/onRecordEnd 不直接停录音，仅保险，正常情况下不走）
        id rec = [MyVoiceDirectSend stashedQQRecorder];
        id op  = [MyVoiceDirectSend stashedQQOperator];
        BOOL did = NO;
        if (rec) { [MyVoiceDirectSend mvQQSendRecorder:rec]; did = YES; }
        if (op)  { MVInvoke(op, @"onRecordEnd:send:", @[[NSNull null], @YES]); did = YES; }
        if (!did) MVLog(@"[direct] ⚠️ QQ 停止时 recorder/operator/PushToTalkView 均不可用（无法结束）");
        return did ? @"QQ 兜底结束" : @"(无)";
    }
    if (stopTarget) {
        if (isSender) {
            MVInvoke(stopTarget, @"StopRecord", nil);
            return @"AudioSender -StopRecord";
        }
        if ([stopTarget respondsToSelector:NSSelectorFromString(@"StopRecordingInternal:")]) {
            MVInvoke(stopTarget, @"StopRecordingInternal:", nil);
            return @"RecordController -StopRecordingInternal:";
        }
        MVInvoke(stopTarget, @"StopRecordingAndSend", nil);
        return @"RecordController -StopRecordingAndSend";
    }
    if (rc) {
        MVInvoke(rc, @"StopRecordingInternal:", nil);
        return @"RecordController -StopRecordingInternal:（兜底）";
    }
    MVLog(@"[direct] ⚠️ 没有任何可用的停止入口，可能需手动松手/等微信自动结束");
    return @"(无)";
}

// 取消录音（直发未接管时收尾，避免麦克风一直开着）
+ (void)cancelWith:(id)stopTarget sender:(BOOL)isSender fallbackRC:(id)rc {
    id t = stopTarget ?: rc;
    if (!t) return;
    // ★ 2.8.22：QQ 取消 = 结束但不发送。优先 recorder -stopRecord，再用 operator
    //   -onRecordEnd:send:(NO) 兜底（任一能停即可，避免麦克风常开 / 残留录音会话）。
    if ([MyVoiceDirectSend qqAvailable]) {
        // ★ 2.8.23：取消也走 touchEnd:（停止优先，与发送同一真实入口）。
        //   QQ 松手即发送、上滑才取消；自动模式下「停止」是首要诉求，故取消 = 模拟松手停止。
        @synchronized([MyVoiceDirectSend class]) {
            id view = g_mvQQPushToTalkView;
            // ★ 2.8.23：同上，不检查 window（验证证明 touchEnd: 触停不依赖 window）
            if (view && [view respondsToSelector:NSSelectorFromString(@"touchEnd:")]) {
                UITouch *to = [MyVoiceDirectSend mvSyntheticTouchOnView:view phase:UITouchPhaseEnded];
                @try {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [view performSelector:NSSelectorFromString(@"touchEnd:") withObject:to];
                    #pragma clang diagnostic pop
                    MVLog(@"[direct] QQ 取消：已模拟松手 touchEnd:（停止）");
                    return;
                } @catch (NSException *e) {
                    MVLog(@"[direct] QQ 取消 touchEnd: 异常 %@", e.reason);
                }
            }
        }
        id rec = [MyVoiceDirectSend stashedQQRecorder];
        id op  = [MyVoiceDirectSend stashedQQOperator];
        if (rec) { MVInvoke(rec, @"stopRecord", nil); MVLog(@"[direct] QQ 取消：recorder -stopRecord（兜底）"); }
        if (op)  { MVInvoke(op, @"onRecordEnd:send:", @[[NSNull null], @NO]); MVLog(@"[direct] QQ 取消：operator -onRecordEnd:send:(NO)（兜底）"); }
        if (!rec && !op) MVLog(@"[direct] QQ 取消：无 recorder/operator/PushToTalkView 可调用");
        return;
    }
    for (NSString *sel in @[@"CancelRecording", @"CancelRecord", @"StopRecording", @"StopRecord"]) {
        if ([t respondsToSelector:NSSelectorFromString(sel)]) {
            MVInvoke(t, sel, nil);
            MVLog(@"[direct] 已调用取消：-%@", sel);
            return;
        }
    }
}

@end
