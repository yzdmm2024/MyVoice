#import "MyVoicePanel.h"
#import "MyVoiceCommon.h"
#import "MyVoiceEngine.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceCloneController.h"
#import <UIKit/UIKit.h>

@interface MyVoicePanel ()
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UISegmentedControl *voiceSeg;
@property (nonatomic, strong) UIView *dragBar;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UILabel *sessionLabel;
@property (nonatomic, strong) NSTimer *sessionTimer;
@end

@implementation MyVoicePanel
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

#define MV_PANEL_W 290.0
#define MV_PANEL_H 348.0

- (NSArray<NSDictionary*>*)voiceList {
    // 千问模式：官方预置音色，无需克隆；CosyVoice 模式：用户克隆/设计的音色
    if (MVTTSProvider() == 1) return MVQwenVoiceList();
    return MVVoices();
}

- (void)show {
    // 面板可能被跨进程通知 / 后台回调触发，统一回主线程再动 UIKit
    if (![NSThread isMainThread]) { MVOnMain(^{ [self show]; }); return; }
    if (self.fab) return;
    UIWindow *w = [MyVoiceResolver anyWindow];
    if (!w) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self show]; }); return; }

    self.fab = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.fab setTitle:@"语" forState:UIControlStateNormal];
    self.fab.backgroundColor = [UIColor systemBlueColor];
    self.fab.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.fab.layer.cornerRadius = 28; self.fab.clipsToBounds = YES;
    self.fab.frame = CGRectMake(w.bounds.size.width - 64, w.bounds.size.height - 160, 56, 56);
    [w addSubview:self.fab];
    [self.fab addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self addDrag:self.fab];

    [self buildPanel];
}

- (void)hide {
    if (![NSThread isMainThread]) { MVOnMain(^{ [self hide]; }); return; }
    [self stopSessionTimer];
    [self.fab removeFromSuperview]; self.fab = nil;
    [self.panel removeFromSuperview]; self.panel = nil;
}

- (void)buildPanel {
    UIWindow *w = [MyVoiceResolver anyWindow];
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(w.bounds.size.width - MV_PANEL_W - 20,
                                                         w.bounds.size.height - MV_PANEL_H - 90,
                                                         MV_PANEL_W, MV_PANEL_H)];
    self.panel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.panel.layer.cornerRadius = 14; self.panel.layer.shadowOpacity = 0.3; self.panel.layer.shadowRadius = 10;
    self.panel.hidden = YES;

    // ---- 顶部拖动条：整块面板可以拖着走（手机屏幕内自由移动）----
    self.dragBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MV_PANEL_W, 30)];
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, 160, 20)];
    titleLbl.text = @"我的语音";
    titleLbl.font = [UIFont boldSystemFontOfSize:13];
    [self.dragBar addSubview:titleLbl];
    UILabel *grip = [[UILabel alloc] initWithFrame:CGRectMake(MV_PANEL_W - 44, 4, 32, 20)];
    grip.text = @"≡";
    grip.textAlignment = NSTextAlignmentCenter;
    grip.font = [UIFont systemFontOfSize:16];
    grip.textColor = [UIColor secondaryLabelColor];
    [self.dragBar addSubview:grip];
    [self.panel addSubview:self.dragBar];

    // 面板整体也能拖（拖空白处即可；文字框内是滚动，走标题栏）
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)];
    [p setMinimumNumberOfTouches:1];
    [self.panel addGestureRecognizer:p];
    UIPanGestureRecognizer *p2 = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)];
    [self.dragBar addGestureRecognizer:p2];

    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(12, 34, MV_PANEL_W - 24, 84)];
    self.textView.layer.cornerRadius = 8; self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    [self.panel addSubview:self.textView];

    NSArray *vs = [self voiceList];
    NSMutableArray *titles = [NSMutableArray array];
    if (vs.count == 0) [titles addObject:(MVTTSProvider() == 1) ? @"(无音色)" : @"(未创建音色)"];
    for (NSDictionary *d in vs) [titles addObject:d[@"name"] ?: @"音色"];
    self.voiceSeg = [[UISegmentedControl alloc] initWithItems:titles];
    self.voiceSeg.frame = CGRectMake(12, 124, MV_PANEL_W - 24, 30);
    // 默认选中当前音色
    NSString *cur = (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
    NSInteger sel = 0;
    for (NSInteger i=0;i<(int)vs.count;i++) if ([vs[i][@"voiceID"] isEqualToString:cur]) sel = i;
    self.voiceSeg.selectedSegmentIndex = (vs.count? sel : -1);
    [self.panel addSubview:self.voiceSeg];

    UIButton *send = [UIButton buttonWithType:UIButtonTypeSystem];
    [send setTitle:@"① 合成语音" forState:UIControlStateNormal];
    send.backgroundColor = [UIColor systemBlueColor]; [send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    send.frame = CGRectMake(12, 162, 120, 40); send.layer.cornerRadius = 8;
    [send addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:send];

    UIButton *clone = [UIButton buttonWithType:UIButtonTypeSystem];
    [clone setTitle:@"音色管理" forState:UIControlStateNormal];
    clone.frame = CGRectMake(150, 162, MV_PANEL_W - 162, 40); clone.layer.cornerRadius = 8;
    clone.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [clone addTarget:self action:@selector(onClone) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:clone];

    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    [prev setTitle:@"预览" forState:UIControlStateNormal];
    prev.frame = CGRectMake(12, 210, MV_PANEL_W - 24, 36); prev.layer.cornerRadius = 8;
    prev.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [prev addTarget:self action:@selector(onPreview) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:prev];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12, 252, MV_PANEL_W - 24, 16)];
    hint.text = @"顶部标题栏可拖动面板";
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [UIColor tertiaryLabelColor];
    [self.panel addSubview:hint];

    // ---- 当前会话（点一下重新识别）----
    self.sessionLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 272, MV_PANEL_W - 24, 20)];
    self.sessionLabel.font = [UIFont systemFontOfSize:11];
    self.sessionLabel.numberOfLines = 1;
    self.sessionLabel.adjustsFontSizeToFitWidth = YES;
    self.sessionLabel.minimumScaleFactor = 0.7;
    self.sessionLabel.userInteractionEnabled = YES;
    [self.sessionLabel addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(refreshSession)]];
    [self.panel addSubview:self.sessionLabel];
    [self refreshSession];

    // ---- 右下角关闭按钮 ----
    self.closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    self.closeBtn.frame = CGRectMake(MV_PANEL_W - 12 - 72, MV_PANEL_H - 12 - 36, 72, 36);
    self.closeBtn.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.closeBtn.layer.cornerRadius = 9;
    self.closeBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.closeBtn];

    [w addSubview:self.panel];
}

- (void)closePanel { self.panel.hidden = YES; [self stopSessionTimer]; }

#pragma mark - 会话状态（面板可见时每秒刷新，最容易发现"识别不到"）

- (void)refreshSession {
    NSString *s = [[MyVoiceManager shared] talkerStatus];
    BOOL ok = [s rangeOfString:@"未识别"].location == NSNotFound;
    self.sessionLabel.text = [NSString stringWithFormat:@"%@  %@", s, ok ? @"✅" : @"（点我重试）"];
    self.sessionLabel.textColor = ok ? [UIColor systemBlueColor] : [UIColor systemOrangeColor];
}

- (void)startSessionTimer {
    if (self.sessionTimer) return;
    self.sessionTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self
        selector:@selector(refreshSession) userInfo:nil repeats:YES];
}
- (void)stopSessionTimer {
    [self.sessionTimer invalidate]; self.sessionTimer = nil;
}

// 面板拖动：限制在屏幕内（顶部留 24pt，避免被状态栏/刘海挡住）
- (void)dragPanel:(UIPanGestureRecognizer*)g {
    UIView *host = self.panel.superview;
    if (!host) return;
    CGPoint t = [g translationInView:host];
    CGRect f = self.panel.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    CGFloat maxX = host.bounds.size.width  - f.size.width;
    CGFloat maxY = host.bounds.size.height - f.size.height;
    f.origin.x = MAX(0, MIN(MAX(0, maxX), f.origin.x));
    f.origin.y = MAX(24, MIN(MAX(24, maxY), f.origin.y));
    self.panel.frame = f;
    [g setTranslation:CGPointZero inView:host];
}

- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    if (self.panel.hidden) [self stopSessionTimer];
    else { [self refreshSession]; [self startSessionTimer]; }
}

- (NSString*)selectedVoiceID {
    NSInteger idx = self.voiceSeg.selectedSegmentIndex;
    NSArray *vs = [self voiceList];
    if (idx >= 0 && idx < (int)vs.count) {
        NSString *vid = vs[idx][@"voiceID"] ?: @"";
        if (MVTTSProvider() == 1) {           // 千问：记住选中的预置音色
            [MVPrefs() setObject:vid forKey:@"qwenVoice"];
            [MVPrefs() synchronize];
        }
        return vid;
    }
    return (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
}

- (void)onSend {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    NSString *vid = [self selectedVoiceID];
    if (MVEngineMode()==1 && MVTTSProvider()==0 && !vid.length) { [[MyVoiceManager shared] toast:@"请先创建一个音色"]; return; }
    if (MVTTSProvider()==0) {
        [MVPrefs() setObject:vid forKey:@"currentVoiceID"]; [MVPrefs() synchronize];
    }
    [[MyVoiceManager shared] handleSendText:text];
    self.panel.hidden = YES;
    [self stopSessionTimer];
}

- (void)onPreview {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    [MyVoiceEngine previewText:text voiceID:[self selectedVoiceID]];
}

- (void)onClone {
    MyVoiceCloneController *vc = [[MyVoiceCloneController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    UIViewController *top = [MyVoiceResolver anyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)addDrag:(UIButton*)btn {
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [btn addGestureRecognizer:p];
}
- (void)drag:(UIPanGestureRecognizer*)g {
    UIWindow *w = [MyVoiceResolver anyWindow];
    CGPoint t = [g translationInView:w];
    CGRect f = self.fab.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    f.origin.x = MAX(0, MIN(w.bounds.size.width - f.size.width, f.origin.x));
    f.origin.y = MAX(0, MIN(w.bounds.size.height - f.size.height, f.origin.y));
    self.fab.frame = f;
    [g setTranslation:CGPointZero inView:w];
}
@end
