#import "MyVoicePanel.h"
#import "MyVoiceCommon.h"
#import "MyVoiceEngine.h"
#import "MyVoiceManager.h"
#import <UIKit/UIKit.h>

@interface MyVoicePanel ()
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UISegmentedControl *voiceSeg;
@property (nonatomic, strong) NSArray<NSString*> *voices;
@end

@implementation MyVoicePanel
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

- (NSArray<NSString*>*)voices {
    if (!_voices) {
        NSArray *all = [MyVoiceEngine availableVoiceIDs];
        _voices = all.count ? all : @[@""];
    }
    return _voices;
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
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(w.bounds.size.width - 300, w.bounds.size.height - 360, 280, 300)];
    self.panel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.panel.layer.cornerRadius = 14; self.panel.layer.shadowOpacity = 0.3; self.panel.layer.shadowRadius = 10;
    self.panel.hidden = YES;

    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(12, 12, 256, 110)];
    self.textView.layer.cornerRadius = 8; self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    [self.panel addSubview:self.textView];

    NSArray *vs = [self voices];
    NSInteger max = MIN(5, (int)vs.count);
    NSMutableArray *titles = [NSMutableArray array];
    for (int i = 0; i < max; i++) {
        // 取音色名末段作为显示
        NSString *vid = vs[i];
        NSArray *parts = [vid componentsSeparatedByString:@"."];
        [titles addObject:parts.lastObject ?: vid];
    }
    self.voiceSeg = [[UISegmentedControl alloc] initWithItems:titles];
    self.voiceSeg.frame = CGRectMake(12, 132, 256, 30);
    self.voiceSeg.selectedSegmentIndex = 0;
    [self.panel addSubview:self.voiceSeg];

    UIButton *send = [UIButton buttonWithType:UIButtonTypeSystem];
    [send setTitle:@"发送语音" forState:UIControlStateNormal];
    send.backgroundColor = [UIColor systemBlueColor]; [send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    send.frame = CGRectMake(12, 176, 120, 40); send.layer.cornerRadius = 8;
    [send addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:send];

    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    [prev setTitle:@"预览" forState:UIControlStateNormal];
    prev.frame = CGRectMake(148, 176, 120, 40); prev.layer.cornerRadius = 8;
    prev.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [prev addTarget:self action:@selector(onPreview) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:prev];

    [w addSubview:self.panel];
}

- (void)togglePanel { self.panel.hidden = !self.panel.hidden; }

- (void)onSend {
    NSString *text = self.textView.text ?: @"";
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    NSInteger idx = self.voiceSeg.selectedSegmentIndex;
    NSString *vid = (idx >= 0 && idx < (int)self.voices.count) ? self.voices[idx] : @"";
    [[MyVoiceManager shared] handleSendText:text];
    self.panel.hidden = YES;
    // 记住默认音色
    if (vid.length) { [MVPrefs() setObject:vid forKey:@"voiceID"]; [MVPrefs() synchronize]; }
}

- (void)onPreview {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    NSInteger idx = self.voiceSeg.selectedSegmentIndex;
    NSString *vid = (idx >= 0 && idx < (int)self.voices.count) ? self.voices[idx] : @"";
    [MyVoiceEngine previewText:text voiceID:vid];
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
