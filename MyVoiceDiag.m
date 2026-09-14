#import "MyVoiceDiag.h"
#import "MyVoiceCommon.h"
#import <objc/runtime.h>

// ============================================================
// 2.8.17 真机抓包：QQ 进程内的类名 / 方法 / 视图树 / 手势 全量导出。
// 全部 [mvdiag] 前缀，仅 NSLog，不 hook 任何发送逻辑。
// ============================================================

BOOL mvDiagIsQQ(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    return [bid rangeOfString:@"tencent.mqq"].location != NSNotFound;
}

// ★ 2.8.24：抖音（Aweme）进程判断。bundle id = com.ss.iphone.ugc.Aweme。
BOOL mvDiagIsDouyin(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    return [bid rangeOfString:@"aweme" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [bid rangeOfString:@"ugc.iphone" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// 枚举 QQ 里所有"看着像录音/语音/按住说话"的类，并打印最相关类的方法签名
void mvDiagDumpClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { MVLog(@"[mvdiag] objc_getClassList 失败"); return; }
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) { MVLog(@"[mvdiag] malloc 失败"); return; }
    objc_getClassList(classes, count);

    NSMutableArray *hit = [NSMutableArray new];
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        NSString *n = NSStringFromClass(c);
        if (!n) continue;
        if ([n containsString:@"Ptt"] || [n containsString:@"Record"] ||
            [n containsString:@"Voice"] || [n containsString:@"Operator"] ||
            [n containsString:@"Speak"] || [n containsString:@"AudioSender"] ||
            [n containsString:@"RecordBtn"] || [n containsString:@"Press"] ||
            [n containsString:@"AIOInput"] || [n containsString:@"ChatInput"] ||
            [n containsString:@"InputBar"] || [n containsString:@"PttRecord"]) {
            [hit addObject:n];
        }
    }
    free(classes);
    MVLog(@"[mvdiag] 命中相关类(%lu)：%@", (unsigned long)hit.count, hit);

    // 对"最像录音控制"的类，打印方法签名（找真正的开始/结束录制选择器）
    NSArray *interesting = @[@"PttRecordOperator", @"PttRecorder", @"RecordOperator",
                             @"RecordBtn", @"RecordController", @"PttRecordManager",
                             @"AIOInput", @"ChatInput", @"InputBar", @"PttRecordBtn"];
    for (NSString *kw in interesting) {
        for (NSString *n in hit) {
            if ([n containsString:kw]) {
                Class c = NSClassFromString(n);
                if (!c) continue;
                unsigned int m = 0;
                Method *ms = class_copyMethodList(c, &m);
                NSMutableArray *sigs = [NSMutableArray new];
                for (unsigned i = 0; i < m; i++) {
                    NSString *s = NSStringFromSelector(method_getName(ms[i]));
                    if ([s containsString:@"Record"] || [s containsString:@"record"] ||
                        [s containsString:@"Ptt"] || [s containsString:@"Start"] ||
                        [s containsString:@"Stop"] || [s containsString:@"Trig"] ||
                        [s containsString:@"Send"] || [s containsString:@"Touch"] ||
                        [s containsString:@"Press"] || [s containsString:@"Begin"] ||
                        [s containsString:@"End"] || [s containsString:@"Audio"]) {
                        [sigs addObject:s];
                    }
                }
                free(ms);
                if (sigs.count)
                    MVLog(@"[mvdiag] %@ 相关方法(%lu)：%@", n, (unsigned long)sigs.count, sigs);
            }
        }
    }
}

// 读取手势的 target/action（私有 _targets / _action，best-effort）
NSString *mvDiagGRInfo(UIGestureRecognizer *gr) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@", NSStringFromClass([gr class])];
    @try {
        NSArray *targets = [gr valueForKey:@"_targets"];
        if (targets.count) {
            NSMutableArray *acts = [NSMutableArray new];
            for (id t in targets) {
                id act = [t valueForKey:@"_action"];
                SEL sel = NULL;
                if ([act isKindOfClass:[NSValue class]]) sel = (SEL)[(NSValue *)act pointerValue];
                else if ([act isKindOfClass:[NSString class]]) sel = NSSelectorFromString(act);
                if (sel) [acts addObject:NSStringFromSelector(sel)];
                else {
                    id tg = [t valueForKey:@"_target"];
                    if (tg) [acts addObject:[NSString stringWithFormat:@"target=%@", NSStringFromClass([tg class])]];
                }
            }
            if (acts.count) [s appendFormat:@" act=%@", acts];
        }
    } @catch (NSException *e) { }
    return s;
}

// 递归 dump 聊天输入区视图树：自定义类展开，纯系统子树折叠，避免刷屏
static void mvDumpRec(UIView *v, int d, int *counter) {
    if (!v || d > 14 || *counter > 400) return;
    (*counter)++;
    NSString *cn = NSStringFromClass([v class]);
    BOOL sys = [cn hasPrefix:@"NS"] || [cn hasPrefix:@"UI"] || [cn hasPrefix:@"CA"] ||
               [cn hasPrefix:@"_"] || [cn hasPrefix:@"WK"] || [cn hasPrefix:@"PK"] ||
               [cn hasPrefix:@"__"];
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(d * 2) withString:@" " startingAtIndex:0];
    NSString *tag = [v isKindOfClass:[UIControl class]] ? @"(UIControl)" : @"";
    MVLog(@"[mvdiag]   %@%@%@ subviews=%lu", pad, cn, tag, (unsigned long)v.subviews.count);
    if (sys) {
        int custom = 0;
        for (UIView *s in v.subviews)
            if (!([NSStringFromClass([s class]) hasPrefix:@"NS"] ||
                  [NSStringFromClass([s class]) hasPrefix:@"UI"] ||
                  [NSStringFromClass([s class]) hasPrefix:@"CA"] ||
                  [NSStringFromClass([s class]) hasPrefix:@"_"])) custom++;
        if (custom == 0) return; // 纯系统子树，跳过
    }
    for (UIView *s in v.subviews) mvDumpRec(s, d + 1, counter);
}

void MVDebugDumpInputTree(UIView *root) {
    if (!root) { MVLog(@"[mvdiag] 视图树：root 为空"); return; }
    MVLog(@"[mvdiag] ===== 聊天输入区视图树（自定义类展开 / 系统类折叠）=====");
    int c = 0;
    mvDumpRec(root, 0, &c);
    MVLog(@"[mvdiag] ===== 视图树结束（共 %d 个节点）=====", c);
}
