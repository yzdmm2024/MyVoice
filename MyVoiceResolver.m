#import "MyVoiceResolver.h"
#import "MyVoiceCommon.h"

@implementation MyVoiceResolver

+ (Class)classWithCandidates:(NSArray<NSString*>*)names {
    // ★ 2.2.8：这里是全项目唯一的「宿主类名批量解析」入口（BaseMsgContentViewController /
    //   MMServiceCenter / CContactMgr ...）。宿主未就绪时解析会把宿主类强行 realize
    //   并触发其 +initialize → 直接崩（详见 MyVoiceCommon.h 顶部长注释）。
    if (!MVHostReady()) return nil;
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (c) return c;
    }
    return nil;
}

+ (SEL)selectorWithCandidates:(Class)cls names:(NSArray<NSString*>*)sels {
    if (!cls) return NULL;
    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        if (sel && [cls instancesRespondToSelector:sel]) return sel;
    }
    return NULL;
}

+ (id)valueForIvars:(id)obj names:(NSArray<NSString*>*)ivars {
    if (!obj) return nil;
    for (NSString *iv in ivars) {
        @try { id v = [obj valueForKey:iv]; if (v) return v; } @catch (NSException *e) {}
        Ivar ivar = class_getInstanceVariable(object_getClass(obj), iv.UTF8String);
        if (ivar) { id v = object_getIvar(obj, ivar); if (v) return v; }
    }
    return nil;
}

+ (NSArray<NSString*>*)chatVCCandidates {
    return @[@"BaseMsgContentViewController", @"MsgContentViewController",
             @"MessageViewController", @"NewMainFrameViewController",
             @"ConversationView", @"ChatRoomView", @"BaseMsgContentViewControllerEx"];
}
+ (NSArray<NSString*>*)talkerIvarCandidates {
    return @[@"m_nsTalker", @"m_nsFromUsr", @"talker", @"nsTalker",
             @"m_nsUserName", @"m_nsChatName", @"wxid_", @"m_userName"];
}
+ (NSArray<NSString*>*)recordStartCandidates {
    return @[@"StartRecordFrom:ToUser:UserInfo:", @"startRecording:",
             @"onRecordButtonDown:", @"beginRecording", @"startVoiceRecord:",
             @"startRecording", @"onVoiceRecordStart:"];
}
+ (NSArray<NSString*>*)recordEndCandidates {
    return @[@"OnRecorderEndRecording:UserData:", @"stopRecording",
             @"onRecordButtonUp:", @"endRecording", @"stopVoiceRecord",
             @"onVoiceRecordStop:", @"finishRecording"];
}
+ (NSArray<NSString*>*)sendVoiceCandidates {
    // 微信 8.0.75 实测：老 tweak 用的 sendVoiceToWeChat:toUsr: **已不存在**。
    // 现在真正可用的直发口是 CMessageMgr -AddMsg:MsgWrap:（见 MyVoiceSender 的 directSendSilk:）。
    // 这里保留候选清单只是为了兼容老版本微信。
    return @[@"AddMsg:MsgWrap:", @"SendOriVoiceMsgWithUserData:",
             @"sendVoiceToWeChat:toUsr:", @"sendVoice:toUsr:"];
}
+ (NSArray<NSString*>*)audioSenderCandidates {
    return @[@"AudioSender", @"VoiceSender", @"RecorderSender"];
}

#pragma mark - VC 树遍历

// 收集所有 window 的 rootViewController（兼容 iOS13+ 多 scene），避免只取 keyWindow 漏掉微信主窗
+ (NSArray<UIViewController*>*)allRootViewControllers {
    NSMutableArray *roots = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene*)scene;
        for (UIWindow *w in ws.windows) {
            if (w.rootViewController) {
                UIViewController *top = [self topOf:w.rootViewController];
                if (top) [roots addObject:top];
            }
        }
    }
    if (!roots.count) {
        UIWindow *kw = UIApplication.sharedApplication.keyWindow;
        if (kw.rootViewController) [roots addObject:[self topOf:kw.rootViewController]];
    }
    return roots;
}

+ (UIViewController*)topOf:(UIViewController*)vc {
    while (vc) {
        if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController*)vc).selectedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController*)vc).visibleViewController;
        else if (vc.presentedViewController) vc = vc.presentedViewController;
        else break;
    }
    return vc;
}

+ (UIViewController*)topViewController {
    NSArray *roots = [self allRootViewControllers];
    return roots.firstObject;
}

// 取一个可用窗口。keyWindow 在 iOS13+ 多 scene 下经常是 nil（尤其微信这种多窗口 app），
// 所以逐层兜底。⚠️ 只能在主线程调用（读 windows/connectedScenes 属 UIKit 访问）。
+ (UIWindow*)anyWindow {
    UIWindow *kw = UIApplication.sharedApplication.keyWindow;
    if (kw) return kw;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene*)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *w = ((UIWindowScene*)scene).windows.firstObject;
        if (w) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

#pragma mark - 聊天对象识别（微信 8.0.75 实测路径，见下方注释）

// ============================================================
// 为什么原来是坏的（frida 注入 WeChat 8.0.75.33 实测）：
//   · BaseMsgContentViewController 的 316 个 ivar / 全部父类 ivar 里
//     **完全没有 talker / user / session 字段**，所以老代码「扫 VC 字段找 wxid」
//     必然一无所获 → 一直弹「未识别到聊天对象」，按多少次说话都没用。
//   · 真正的会话在另一个对象上：BaseMsgContentLogicController.m_contact (@"CBaseContact")，
//     且 VC 自己就暴露了 -getChatUserName / -GetContact / -GetCContact。
// 解析优先级：
//   ① VC -getChatUserName                （最直接，返回会话 wxid）
//   ② VC -GetContact / -GetCContact       → CContact.m_nsUsrName
//   ③ VC.m_contact                        → CContact.m_nsUsrName
//   ④ VC.m_delegate（=LogicController）.m_contact / -getCurrentContact
//   ⑤ 当前会话窗口里的消息 CMessageWrap（m_nsFromUsr = xx@chatroom 时可用）
//   ⑥ 老套路：扫 VC 字段（仅少数老版本有效）
//   ⑦ 本进程/落盘记住的上次捕获值（hook 聊天页出现时写入）
// ============================================================

static NSString *_mvCaptured = nil;      // 进程内缓存
static NSTimeInterval _mvCapturedAt = 0; // 捕获时间（30 分钟内有效）

// ★ 2.3.0：放松校验。getChatUserName 返回的是**会话对方的真实微信号**，而很多用户的
//   微信号是自定义 ID（如 zhang3abc、mr_li-01），并不以 wxid_ 开头 —— sanitize 一律拒掉，
//   导致「明明就在聊天页里也提示未识别到聊天对象」。这里按微信 ID 本身的字符规则
//   （字母开头，6~32 位字母/数字/_/-，不含空格和 CJK）放行这种自定义 ID。
//   只用于 getChatUserName 的返回值（VC 自己的 getter，不会返回昵称），其他路径仍走严格 sanitize。
+ (NSString*)sanitizeName:(NSString*)s {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 6 || t.length > 32) return nil;
    static NSPredicate *pred = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pred = [NSPredicate predicateWithFormat:
                             @"SELF MATCHES '^[A-Za-z][A-Za-z0-9_-]{5,31}$'"]; });
    return [pred evaluateWithObject:t] ? t : nil;
}

// 只认微信内部标识。放宽会把「昵称」当会话 id 发出去 → 发错人，宁可识别不出来。
+ (NSString*)sanitize:(NSString*)s {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 3) return nil;
    if ([t hasPrefix:@"wxid_"]) return t;
    if ([t hasPrefix:@"gh_"]) return t;
    if ([t rangeOfString:@"@chatroom"].location != NSNotFound) return t;
    if ([t rangeOfString:@"@openim"].location != NSNotFound) return t;
    if ([t rangeOfString:@"@im.chat"].location != NSNotFound) return t;
    return nil;
}

// 安全调用一个「返回对象」的无参方法（返回非对象时会被截断，这里只用于字符串 getter）
+ (id)call:(id)obj name:(NSString*)n {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(n);
    if (!sel || ![obj respondsToSelector:sel]) return nil;
    @try {
        IMP imp = [obj methodForSelector:sel];
        if (!imp) return nil;
        return ((id (*)(id, SEL))imp)(obj, sel);
    } @catch (NSException *e) { return nil; }
}

// 从联系人对象（CContact / CBaseContact / 字符串）里取 wxid
+ (NSString*)talkerFromContact:(id)c {
    if (!c) return nil;
    if ([c isKindOfClass:[NSString class]]) return [self sanitize:c];
    for (NSString *k in @[@"m_nsUsrName", @"m_nsUserName", @"nsUsrName", @"m_nsEncryptUserName", @"userName"]) {
        NSString *t = [self sanitize:[self valueForIvars:c names:@[k]]];
        if (t) return t;
    }
    return nil;
}

// 从一条消息里取会话 id。只信「群」：from 就是群 id。1:1 时 from/to 哪个是自己分不清，
// 胡猜会发错人，所以直接放弃，交给前面的路径。
+ (NSString*)talkerFromMsgWrap:(id)w {
    if (!w) return nil;
    NSString *from = [self sanitize:[self valueForIvars:w names:@[@"m_nsFromUsr", @"m_nsToUsr"]]];
    if (from && [from rangeOfString:@"@chatroom"].location != NSNotFound) return from;
    return nil;
}

// ★ 2.2.9：把 id 交给 object_getClass 之前的最后一道闸门。
//   为什么必须有：object_getClass 对「已释放且内存已被复用」的对象会在 libobjc 的
//   _objc_opt_class 里触发断言 → SIGTRAP(EXC_BREAKPOINT)。这**不是** NSException，
//   @try/@catch 完全抓不住，进程直接死 —— 2.2.8 的闪退栈顶正是 object_getClass。
//   这里做零成本粗筛：未按 8 字节对齐 / isa 为空或未对齐 的指针直接否掉；
//   tagged pointer（NSNumber/NSDate 等）永远是合法对象，直接放行。
static BOOL MVLooksLikeObject(id o) {
    if (!o) return NO;
    uintptr_t p = (uintptr_t)o;
    if (p & 0x7UL) return NO;                    // 未按指针宽度对齐 → 绝不可能是对象
    if (p & (1UL << 63)) return YES;             // tagged pointer → 合法
    uintptr_t isa = *(volatile uintptr_t *)p;    // 直接读 isa，绕开 objc 的断言路径
    if (isa == 0) return NO;
    if (isa & 0x7UL) return NO;                  // isa 未对齐 → 内存已被复用写脏
    return YES;
}

// 判定「这个 VC 是不是聊天页」
+ (BOOL)isChatVC:(id)vc {
    if (!MVLooksLikeObject(vc)) return NO;
    Class cls = object_getClass(vc);
    if (!cls) return NO;
    NSString *cn = NSStringFromClass(cls);
    if (![cn isKindOfClass:[NSString class]] || !cn.length) return NO;
    return [cn rangeOfString:@"MsgContent"].location != NSNotFound;
}

// ★ 2.2.9：延迟补抓入口 —— **不持有任何外部对象**。
//   起因：2.2.8 在 -viewDidAppear: 里写了
//       dispatch_after(0.8s, ^{ [MyVoiceResolver captureFromChatVC:self]; });
//   而微信启动/切页时 viewDidAppear 内部会自我销毁旧 VC，0.8s 后 self 已 dealloc，
//   object_getClass(野指针) → SIGTRAP。改走这里：到时重新遍历活着的 VC 树，永不碰失效指针。
+ (void)captureFromLatestChatVC {
    NSArray *vcs = nil;
    @try { vcs = [self allViewControllers]; } @catch (NSException *e) { return; }
    for (UIViewController *vc in vcs) {
        if (![self isChatVC:vc]) continue;
        [self captureFromChatVC:vc];
        return;                                  // 只抓最靠上的一个聊天页
    }
}

+ (NSString*)talkerFromChatVC:(id)vc {
    if (![self isChatVC:vc]) return nil;

    // ① 直接问它（8.0.75 上 BaseMsgContentViewController / LogicController 都有）。
    //    ★ 2.3.0：自定义微信号（不带 wxid_ 前缀）也算数，否则这种聊天页永远「未识别」。
    NSString *raw = [self call:vc name:@"getChatUserName"];
    NSString *t = [self sanitize:raw] ?: [self sanitizeName:raw];
    if (t) return t;

    // ② GetContact / GetCContact → m_nsUsrName
    for (NSString *m in @[@"GetContact", @"GetCContact", @"getCurrentContact"]) {
        t = [self talkerFromContact:[self call:vc name:m]];
        if (t) return t;
    }

    // ③ 自己的 m_contact
    t = [self talkerFromContact:[self valueForIvars:vc names:@[@"m_contact", @"m_oContact", @"contact"]]];
    if (t) return t;

    // ④ 逻辑控制器（VC.m_delegate 就是它，实测持有 m_contact）
    id dg = [self valueForIvars:vc names:@[@"m_delegate", @"m_logicController", @"m_oLogicController", @"logicController"]];
    if (dg) {
        t = [self talkerFromContact:[self valueForIvars:dg names:@[@"m_contact"]]];
        if (!t) t = [self talkerFromContact:[self call:dg name:@"getCurrentContact"]];
        if (!t) {
            NSString *raw2 = [self call:dg name:@"getChatUserName"];
            t = [self sanitize:raw2] ?: [self sanitizeName:raw2];
        }
        if (t) return t;
    }

    // ⑤ 当前会话窗口里的消息（只对群有效）
    for (NSString *f in @[@"m_lastMsgInNewArray", @"m_firstUnReadMsg", @"m_scrollTargetMsg",
                          @"_locateMsg", @"m_currentSpeakTextMsg", @"m_referOwnerMsg"]) {
        t = [self talkerFromMsgWrap:[self valueForIvars:vc names:@[f]]];
        if (t) return t;
    }

    // ⑥ 老套路兜底（仅老版本或特殊页面有效）
    t = [self scanTalkerInObject:vc depth:0];
    if (t) return t;
    return [self looseScan:vc];
}

+ (NSArray<UIViewController*>*)allViewControllers {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithArray:[self allRootViewControllers]];
    int guard = 0;
    while (stack.count && guard++ < 400) {
        UIViewController *vc = stack.lastObject; [stack removeLastObject];
        [out addObject:vc];
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    return out;
}

+ (void)captureFromChatVC:(id)vc {
    NSString *t = [self talkerFromChatVC:vc];
    if (!t.length) return;
    if ([t isEqualToString:_mvCaptured]) return;   // 没变就不折腾落盘
    _mvCaptured = t;
    _mvCapturedAt = [[NSDate date] timeIntervalSince1970];
    MVSetLastTalker(t);
    MVLog(@"[talker] 已捕获会话 %@（写入共享配置）", t);
}

+ (NSString*)capturedTalker {
    if (_mvCaptured.length && [[NSDate date] timeIntervalSince1970] - _mvCapturedAt < 1800)
        return _mvCaptured;
    return MVLastTalker();
}

+ (NSString*)currentTalker {
    // ① 活着的聊天页（最准）
    for (UIViewController *vc in [self allViewControllers]) {
        NSString *t = [self talkerFromChatVC:vc];
        if (t) return t;
    }
    // ② 之前 hook 捕获 / 落盘记住的
    return [self capturedTalker];
}

// ★ 2.3.0：当前打开的聊天页 VC 实例。自动发送链路在 wxid 解析失败时用它判断
//   「用户是否就在聊天页里」，从而决定继续尝试而不是直接报错。⚠️ 主线程调用。
+ (UIViewController*)currentChatVC {
    for (UIViewController *vc in [self allViewControllers]) {
        if ([self isChatVC:vc]) return vc;
    }
    return nil;
}

+ (NSString*)talkerDiag {
    NSMutableString *s = [NSMutableString string];
    NSUInteger nChat = 0;
    for (UIViewController *vc in [self allViewControllers]) {
        if (![self isChatVC:vc]) continue;
        nChat++;
        NSString *cn = NSStringFromClass(object_getClass(vc));
        [s appendFormat:@"聊天页 %@\n", cn];
        [s appendFormat:@"  -getChatUserName = %@\n", ([self sanitize:[self call:vc name:@"getChatUserName"]] ?: [self sanitizeName:[self call:vc name:@"getChatUserName"]]) ?: @"(无/空)"];
        id ct = [self call:vc name:@"GetContact"];
        [s appendFormat:@"  -GetContact = %@\n", ct ? NSStringFromClass(object_getClass(ct)) : @"(无)"];
        [s appendFormat:@"  .m_contact = %@\n", [self valueForIvars:vc names:@[@"m_contact"]] ? NSStringFromClass(object_getClass([self valueForIvars:vc names:@[@"m_contact"]])) : @"(无)"];
        id dg = [self valueForIvars:vc names:@[@"m_delegate"]];
        [s appendFormat:@"  .m_delegate = %@\n", dg ? NSStringFromClass(object_getClass(dg)) : @"(无)"];
        if (dg) [s appendFormat:@"    .m_contact.m_nsUsrName = %@\n",
                 [self valueForIvars:[self valueForIvars:dg names:@[@"m_contact"]] names:@[@"m_nsUsrName"]] ?: @"(无)"];
    }
    if (!nChat) [s appendString:@"当前没有打开的聊天页\n"];
    [s appendFormat:@"最终识别 = %@\n", [self currentTalker] ?: @"(失败)"];
    return s;
}

#pragma mark - 调试信息（用户把日志贴回来即可精修微信符号）

+ (BOOL)looksLikeWxid:(NSString*)s {
    if (![s isKindOfClass:[NSString class]] || s.length < 3) return NO;
    if ([s hasPrefix:@"wxid_"]) return YES;
    if ([s containsString:@"@chatroom"]) return YES;
    if ([s containsString:@"@openim"]) return YES;
    if ([s containsString:@"@im.chat"]) return YES;
    return NO;
}

+ (BOOL)nameLooksContact:(NSString*)name {
    NSArray *kw = @[@"talker",@"Talker",@"ToUsr",@"FromUsr",@"toUsr",@"fromUsr",
                    @"Contact",@"contact",@"UsrName",@"userName",@"User",@"Chat",
                    @"chat",@"Session",@"session",@"Conversation",@"conversation",@"m_nsUsr"];
    for (NSString *k in kw) if ([name containsString:k]) return YES;
    return NO;
}

// 收集某对象自身及其父类链（最多 6 层）的全部属性名 + ivar 名
+ (NSMutableArray<NSString*>*)allFieldNamesOf:(Class)cls {
    NSMutableArray *names = [NSMutableArray array];
    Class c = cls; int depth = 0;
    while (c && depth < 6 && ![NSStringFromClass(c) isEqualToString:@"NSObject"]) {
        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList(c, &pc);
        for (unsigned int i=0;i<pc;i++)[names addObject:[NSString stringWithUTF8String:property_getName(props[i])]];
        free(props);
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(c, &ic);
        for (unsigned int i=0;i<ic;i++)[names addObject:[NSString stringWithUTF8String:ivar_getName(ivs[i])]];
        free(ivs);
        c = class_getSuperclass(c); depth++;
    }
    return names;
}

// 扫一个对象找 wxid。depth<=1 时遇到"联系人相关"对象型字段再下钻一层
+ (NSString*)scanTalkerInObject:(id)obj depth:(int)depth {
    if (!obj || depth > 2) return nil;
    Class cls = object_getClass(obj);
    NSMutableArray *names = [self allFieldNamesOf:cls];
    for (NSString *nm in names) {
        if (![self nameLooksContact:nm]) continue;
        id v = nil;
        @try { v = [obj valueForKey:nm]; } @catch (NSException *e) { v = nil; }
        if (!v) {
            Ivar iv = class_getInstanceVariable(cls, nm.UTF8String);
            if (iv) v = object_getIvar(obj, iv);
        }
        if (!v) continue;
        if ([v isKindOfClass:[NSString class]]) {
            if ([self looksLikeWxid:v]) return v;
        } else if (depth < 2) {
            NSString *inner = [self scanTalkerInObject:v depth:depth+1];
            if (inner) return inner;
        }
    }
    return nil;
}

// 宽松：扫所有字符串属性，找像 wxid 的（跳过 UI/NS 系统对象）
+ (NSString*)looseScan:(id)obj {
    if (!obj) return nil;
    Class cls = object_getClass(obj);
    NSString *cn = NSStringFromClass(cls);
    if ([cn hasPrefix:@"UI"] || [cn hasPrefix:@"NS"] || [cn hasPrefix:@"_"]) return nil;
    NSMutableArray *names = [self allFieldNamesOf:cls];
    for (NSString *nm in names) {
        @try {
            id v = [obj valueForKey:nm];
            if ([v isKindOfClass:[NSString class]] && [self looksLikeWxid:v]) return v;
        } @catch (NSException *e) {}
    }
    return nil;
}

#pragma mark - 自己的 wxid / AddMsg 的 arg0（构造语音消息用）

// 自己的 wxid：CContactMgr.getSelfContact → m_nsUsrName。带进程内缓存 + 落共享配置。
+ (NSString*)selfWxid {
    static NSString *cached = nil;
    if (cached.length) return cached;
    // 先看落盘（微信进程重启后不用再问一遍）
    NSString *disk = MVGetStr(@"selfWxid");
    if (disk.length) { cached = disk; return cached; }

    @try {
        id cc = MVService(@"CContactMgr");
        id me = MVCall0(cc, @"getSelfContact");
        id u  = MVCall0(me, @"m_nsUsrName");
        if ([u isKindOfClass:[NSString class]] && [u length]) {
            cached = [u copy];
            MVSetShared(@"selfWxid", cached);
            MVLog(@"[resolver] 自己的 wxid = %@", cached);
        }
    } @catch (NSException *e) {
        MVLog(@"[resolver] 取自己 wxid 异常 %@", e.reason);
    }
    return cached ?: @"";
}

// 微信自己发/收消息时会调 CMessageMgr -AddMsg:MsgWrap:，第一个参数是个**常量对象**
// （实测两次调用同一地址）。直发时要原样复用，所以 hook 里抓下来存住。
static id g_mvAddMsgArg0 = nil;

+ (void)captureAddMsgArg0:(id)arg0 {
    if (!arg0 || g_mvAddMsgArg0) return;
    @try {
        CFRetain((__bridge CFTypeRef)arg0);      // hook 里拿到的往往是 autorelease 的，必须留一份
        g_mvAddMsgArg0 = arg0;
        MVLog(@"[resolver] 捕获 AddMsg arg0 = %@ [%@]", arg0, NSStringFromClass(object_getClass(arg0)));
    } @catch (NSException *e) {}
}

+ (id)capturedAddMsgArg0 { return g_mvAddMsgArg0; }

#pragma mark - 调试信息（用户把日志贴回来即可精修 8.0.76 符号）

+ (NSString*)debugChatInfo {
    NSMutableString *sb = [NSMutableString stringWithString:@"[MyVoice debug]\n"];
    NSArray *roots = [self allRootViewControllers];
    [sb appendFormat:@"rootVCs=%lu\n", (unsigned long)roots.count];
    NSMutableArray *stack = [NSMutableArray arrayWithArray:roots];
    int n = 0;
    while (stack.count && n < 60) {
        UIViewController *vc = stack.lastObject; [stack removeLastObject]; n++;
        NSString *cn = NSStringFromClass(object_getClass(vc));
        BOOL chatLike = [cn containsString:@"MsgContent"] || [cn containsString:@"BaseMsg"]
                        || [cn containsString:@"Chat"] || [cn containsString:@"Conversation"];
        if (chatLike) {
            [sb appendFormat:@"CHAT-LIKE VC: %@\n", cn];
            NSMutableArray *names = [self allFieldNamesOf:object_getClass(vc)];
            for (NSString *nm in names) {
                if (![self nameLooksContact:nm]) continue;
                id v = nil; @try { v = [vc valueForKey:nm]; } @catch (NSException *e) {}
                NSString *vs = [v isKindOfClass:[NSString class]] ? v : (v ? NSStringFromClass(object_getClass(v)) : @"(nil)");
                [sb appendFormat:@"  field %@ = %@\n", nm, vs];
            }
        }
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    NSString *t = [self currentTalker];
    [sb appendFormat:@"DETECTED TALKER = %@\n", t ?: @"(none)"];
    [sb appendFormat:@"---- 路径自检 ----\n%@", [self talkerDiag]];
    return sb;
}

@end
