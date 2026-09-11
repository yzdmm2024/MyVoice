#import "MyVoiceResolver.h"
#import "MyVoiceCommon.h"

@implementation MyVoiceResolver

+ (Class)classWithCandidates:(NSArray<NSString*>*)names {
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
    return @[@"SendOriVoiceMsgWithUserData:", @"sendVoiceToWeChat:toUsr:",
             @"sendVoice:toUsr:", @"sendVoiceMsg", @"sendVoiceData:toUsr:"];
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

// 判定「这个 VC 是不是聊天页」
+ (BOOL)isChatVC:(id)vc {
    if (!vc) return NO;
    NSString *cn = NSStringFromClass(object_getClass(vc));
    return [cn rangeOfString:@"MsgContent"].location != NSNotFound;
}

+ (NSString*)talkerFromChatVC:(id)vc {
    if (![self isChatVC:vc]) return nil;

    // ① 直接问它（8.0.75 上 BaseMsgContentViewController / LogicController 都有）
    NSString *t = [self sanitize:[self call:vc name:@"getChatUserName"]];
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
        if (!t) t = [self sanitize:[self call:dg name:@"getChatUserName"]];
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

+ (NSString*)talkerDiag {
    NSMutableString *s = [NSMutableString string];
    NSUInteger nChat = 0;
    for (UIViewController *vc in [self allViewControllers]) {
        if (![self isChatVC:vc]) continue;
        nChat++;
        NSString *cn = NSStringFromClass(object_getClass(vc));
        [s appendFormat:@"聊天页 %@\n", cn];
        [s appendFormat:@"  -getChatUserName = %@\n", [self sanitize:[self call:vc name:@"getChatUserName"]] ?: @"(无/空)"];
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
