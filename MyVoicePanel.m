#import "MyVoicePanel.h"
#import "MyVoiceCommon.h"
#import "MyVoiceEngine.h"
#import "MyVoiceManager.h"
#import "MyVoiceCloneController.h"
#import <UIKit/UIKit.h>

@interface MyVoicePanel ()
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UISegmentedControl *voiceSeg;
@end

@implementation MyVoicePanel
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

- (NSArray<NSDictionary*>*)voiceList {
    return MVVoices();  // 克隆音色列表（云端模式）
}

- (void)show {
    if (self.fab) return;
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
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
    [self.fab removeFromSuperview]; self.fab = nil;
    [self.panel removeFromSuperview]; self.panel = nil;
}

- (void)buildPanel {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(w.bounds.size.width - 310, w.bounds.size.height - 380, 290, 320)];
    self.panel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.panel.layer.cornerRadius = 14; self.panel.layer.shadowOpacity = 0.3; self.panel.layer.shadowRadius = 10;
    self.panel.hidden = YES;

    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(12, 12, 266, 100)];
    self.textView.layer.cornerRadius = 8; self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    [self.panel addSubview:self.textView];

    NSArray *vs = [self voiceList];
    NSMutableArray *titles = [NSMutableArray array];
    if (vs.count == 0) [titles addObject:@"(未克隆音色)"];
    for (NSDictionary *d in vs) [titles addObject:d[@"name"] ?: @"音色"];
    self.voiceSeg = [[UISegmentedControl alloc] initWithItems:titles];
    self.voiceSeg.frame = CGRectMake(12, 122, 266, 30);
    // 默认选中当前音色
    NSString *cur = MVCurrentVoiceID();
    NSInteger sel = 0;
    for (NSInteger i=0;i<(int)vs.count;i++) if ([vs[i][@"voiceID"] isEqualToString:cur]) sel = i;
    self.voiceSeg.selectedSegmentIndex = (vs.count? sel : -1);
    [self.panel addSubview:self.voiceSeg];

    UIButton *send = [UIButton buttonWithType:UIButtonTypeSystem];
    [send setTitle:@"发送语音" forState:UIControlStateNormal];
    send.backgroundColor = [UIColor systemBlueColor]; [send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    send.frame = CGRectMake(12, 162, 120, 40); send.layer.cornerRadius = 8;
    [send addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:send];

    UIButton *clone = [UIButton buttonWithType:UIButtonTypeSystem];
    [clone setTitle:@"克隆音色" forState:UIControlStateNormal];
    clone.frame = CGRectMake(150, 162, 128, 40); clone.layer.cornerRadius = 8;
    clone.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [clone addTarget:self action:@selector(onClone) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:clone];

    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    [prev setTitle:@"预览" forState:UIControlStateNormal];
    prev.frame = CGRectMake(12, 212, 266, 36); prev.layer.cornerRadius = 8;
    prev.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [prev addTarget:self action:@selector(onPreview) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:prev];

    [w addSubview:self.panel];
}

- (void)togglePanel { self.panel.hidden = !self.panel.hidden; }

- (NSString*)selectedVoiceID {
    NSInteger idx = self.voiceSeg.selectedSegmentIndex;
    NSArray *vs = [self voiceList];
    if (idx >= 0 && idx < (int)vs.count) return vs[idx][@"voiceID"] ?: @"";
    return MVCurrentVoiceID();
}

- (void)onSend {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    NSString *vid = [self selectedVoiceID];
    if (MVEngineMode()==1 && !vid.length) { [[MyVoiceManager shared] toast:@"请先克隆一个音色"]; return; }
    [MVPrefs() setObject:vid forKey:@"currentVoiceID"]; [MVPrefs() synchronize];
    [[MyVoiceManager shared] handleSendText:text];
    self.panel.hidden = YES;
}

- (void)onPreview {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    [MyVoiceEngine previewText:text voiceID:[self selectedVoiceID]];
}

- (void)onClone {
    MyVoiceCloneController *vc = [[MyVoiceCloneController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    UIViewController *top = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)addDrag:(UIButton*)btn {
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [btn addGestureRecognizer:p];
}
- (void)drag:(UIPanGestureRecognizer*)g {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    CGPoint t = [g translationInView:w];
    CGRect f = self.fab.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    f.origin.x = MAX(0, MIN(w.bounds.size.width - f.size.width, f.origin.x));
    f.origin.y = MAX(0, MIN(w.bounds.size.height - f.size.height, f.origin.y));
    self.fab.frame = f;
    [g setTranslation:CGPointZero inView:w];
}
@end
