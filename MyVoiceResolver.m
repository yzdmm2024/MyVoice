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
             @"onRecordButtonDown:", @"beginRecording", @"startVoiceRecord:"];
}
+ (NSArray<NSString*>*)recordEndCandidates {
    return @[@"OnRecorderEndRecording:UserData:", @"stopRecording",
             @"onRecordButtonUp:", @"endRecording", @"stopVoiceRecord"];
}
+ (NSArray<NSString*>*)sendVoiceCandidates {
    return @[@"SendOriVoiceMsgWithUserData:", @"sendVoiceToWeChat:toUsr:",
             @"sendVoice:toUsr:", @"sendVoiceMsg", @"sendVoiceData:toUsr:"];
}
+ (NSArray<NSString*>*)audioSenderCandidates {
    return @[@"AudioSender", @"VoiceSender", @"RecorderSender"];
}

+ (UIViewController*)topViewController {
    UIViewController *rvc = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene*)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow && w.rootViewController) { rvc = w.rootViewController; break; }
            }
        }
    }
    if (!rvc) rvc = UIApplication.sharedApplication.keyWindow.rootViewController;
    return [self topOf:rvc];
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

+ (NSString*)currentTalker {
    NSMutableArray *stack = [NSMutableArray array];
    UIViewController *rvc = [self topViewController];
    if (rvc) [stack addObject:rvc];
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        NSString *cn = NSStringFromClass(object_getClass(vc));
        for (NSString *cand in self.chatVCCandidates) {
            if ([cn isEqualToString:cand]) {
                id talker = [self valueForIvars:vc names:self.talkerIvarCandidates];
                if ([talker isKindOfClass:[NSString class]] && [(NSString*)talker length]) {
                    return talker;
                }
            }
        }
        for (UIViewController *child in vc.childViewControllers) [stack addObject:child];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
    return nil;
}

@end
