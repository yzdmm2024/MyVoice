#import "MyVoiceResolver.h"

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

#pragma mark - 聊天对象识别（版本自适应，运行时自省）

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

+ (NSString*)currentTalker {
    NSArray *roots = [self allRootViewControllers];
    // 第一遍：优先扫类名像聊天的 VC（精准）
    NSMutableArray *stack = [NSMutableArray arrayWithArray:roots];
    while (stack.count) {
        UIViewController *vc = stack.lastObject; [stack removeLastObject];
        NSString *t = [self scanTalkerInObject:vc depth:0];
        if (t) return t;
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    // 第二遍：所有 VC 全量兜底（宽松匹配任意像 wxid 的字符串属性）
    stack = [NSMutableArray arrayWithArray:roots];
    while (stack.count) {
        UIViewController *vc = stack.lastObject; [stack removeLastObject];
        NSString *t = [self looseScan:vc];
        if (t) return t;
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
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
    return sb;
}

@end
