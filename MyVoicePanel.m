#import "MyVoicePanel.h"
#import "MyVoiceCommon.h"
#import "MyVoiceEngine.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceCloneController.h"
#import "MyVoiceCloud.h"
#import <UIKit/UIKit.h>

#define MV_PANEL_W 320.0
#define MV_PANEL_H 280.0
#define MV_FAB_SIZE 38.0

@interface MyVoicePanel () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *homeView;
@property (nonatomic, strong) UIView *pickerView;
@property (nonatomic, strong) UIView *dragBar;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *voiceSelectBtn;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) UIButton *cloneBtn;
@property (nonatomic, strong) UIButton *previewBtn;
@property (nonatomic, strong) UILabel *sessionLabel;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UISegmentedControl *emotionSeg;
@property (nonatomic, strong) UILabel *pickerHintLabel;
@property (nonatomic, strong) UILabel *sectionLabel;
@property (nonatomic, strong) UITableView *voiceTable;
@property (nonatomic, strong) UIButton *reloadBtn;
@property (nonatomic, strong) UIButton *pickerBackBtn;
@property (nonatomic, strong) NSArray *allVoices;
@property (nonatomic, strong) NSArray *filteredVoices;
@property (nonatomic, strong) NSString *selectedVoiceID;
@property (nonatomic, strong) NSTimer *sessionTimer;
@end

@implementation MyVoicePanel
+ (instancetype)shared { static id s; static dispatch_once_t t; dispatch_once(&t,^{ s=[[self alloc] init]; }); return s; }

#pragma mark - Liquid Glass 辅助

+ (UIVisualEffectView*)glassView {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *gv = [[UIVisualEffectView alloc] initWithEffect:effect];
    gv.layer.cornerRadius = 24;
    gv.layer.masksToBounds = YES;
    gv.layer.borderWidth = 0.5;
    gv.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    return gv;
}

+ (void)addGlassHighlight:(UIView*)parent {
    UIView *hl = [[UIView alloc] initWithFrame:CGRectMake(0, 0.5, parent.bounds.size.width, parent.bounds.size.height * 0.45)];
    hl.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
    hl.userInteractionEnabled = NO;
    hl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = hl.bounds;
    g.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.12].CGColor,
                 (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor];
    g.locations = @[@0, @1];
    [hl.layer addSublayer:g];
    [parent addSubview:hl];
}

+ (UIButton*)glassBtn:(NSString*)title style:(NSInteger)style {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 16;
    b.clipsToBounds = YES;
    b.titleLabel.layer.cornerRadius = 16;
    if (style == 0) { // 蓝液态玻璃
        [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.95] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0 alpha:0];
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = CGRectMake(0, 0, 200, 44);
        g.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.35].CGColor,
                     (id)[UIColor colorWithWhite:1 alpha:0.08].CGColor];
        g.startPoint = CGPointMake(0, 0);
        g.endPoint = CGPointMake(0.8, 1);
        [b.layer insertSublayer:g atIndex:0];
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        b.layer.borderWidth = 0.5;
        UIView *hl = [[UIView alloc] initWithFrame:CGRectMake(2, 1, 196, 18)];
        hl.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        hl.userInteractionEnabled = NO;
        CAGradientLayer *hg = [CAGradientLayer layer];
        hg.frame = hl.bounds;
        hg.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.2].CGColor,
                      (id)[UIColor clearColor].CGColor];
        [hl.layer addSublayer:hg];
        [b addSubview:hl];
    } else if (style == 1) { // 白液态玻璃
        [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.75] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        b.layer.borderWidth = 0.5;
        UIView *hl = [[UIView alloc] initWithFrame:CGRectMake(2, 1, 196, 16)];
        hl.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        hl.userInteractionEnabled = NO;
        [b addSubview:hl];
    } else { // subtle
        [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.65] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;
        b.layer.borderWidth = 0.5;
    }
    return b;
}

#pragma mark - 初始化/显示

- (NSArray<NSDictionary*>*)voiceList {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in MVQwenVoiceList()) {
        NSMutableDictionary *m = [d mutableCopy];
        m[@"provider"] = @1;
        [out addObject:m];
    }
    for (NSDictionary *d in MVVoices()) {
        NSMutableDictionary *m = [d mutableCopy];
        m[@"provider"] = @0;
        [out addObject:m];
    }
    return out;
}

- (NSDictionary*)selectedEntry {
    NSString *vid = [self resolvedVoiceID];
    if (!vid.length) return nil;
    for (NSDictionary *d in self.allVoices)
        if ([d[@"voiceID"] isEqualToString:vid]) return d;
    return nil;
}

- (void)show {
    if (![NSThread isMainThread]) { MVOnMain(^{ [self show]; }); return; }
    if (self.fab) return;
    [[MyVoiceCloud shared] prewarmConnection];
    UIWindow *w = [MyVoiceResolver anyWindow];
    if (!w) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self show]; }); return; }

    // ★ 2.7.1：悬浮球 38px + 液态玻璃
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(w.bounds.size.width - MV_FAB_SIZE - 6, w.bounds.size.height * 0.45, MV_FAB_SIZE, MV_FAB_SIZE);
    [fab setTitle:@"语" forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    fab.layer.cornerRadius = MV_FAB_SIZE / 2;
    fab.clipsToBounds = YES;
    fab.backgroundColor = [UIColor clearColor];
    // 液态玻璃球面
    CAGradientLayer *fg = [CAGradientLayer layer];
    fg.frame = CGRectMake(0, 0, MV_FAB_SIZE, MV_FAB_SIZE);
    fg.colors = @[
        (id)[UIColor colorWithWhite:0 alpha:0.2].CGColor,
        (id)[UIColor colorWithRed:0 green:0.4 blue:0.9 alpha:0.35].CGColor,
        (id)[UIColor colorWithRed:0 green:0.2 blue:0.6 alpha:0.4].CGColor];
    fg.locations = @[@0, @0.5, @1];
    fg.startPoint = CGPointMake(0.3, 0.1);
    fg.endPoint = CGPointMake(0.7, 0.9);
    [fab.layer insertSublayer:fg atIndex:0];
    fab.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    fab.layer.borderWidth = 0.5;
    fab.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.3].CGColor;
    fab.layer.shadowOffset = CGSizeMake(0, 2);
    fab.layer.shadowRadius = 6;
    fab.layer.shadowOpacity = 1;
    // 顶部球面高光
    UIView *fh = [[UIView alloc] initWithFrame:CGRectMake(MV_FAB_SIZE*0.15, MV_FAB_SIZE*0.08, MV_FAB_SIZE*0.7, MV_FAB_SIZE*0.35)];
    fh.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    fh.layer.cornerRadius = MV_FAB_SIZE * 0.2;
    fh.userInteractionEnabled = NO;
    CAGradientLayer *fhg = [CAGradientLayer layer];
    fhg.frame = fh.bounds;
    fhg.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.25].CGColor,
                   (id)[UIColor colorWithWhite:0 alpha:0.0].CGColor];
    [fh.layer addSublayer:fhg];
    [fab addSubview:fh];
    self.fab = fab;
    [fab addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self addDrag:fab];
    [w addSubview:fab];
    [self buildPanel];
}

- (void)hide {
    if (![NSThread isMainThread]) { MVOnMain(^{ [self hide]; }); return; }
    [self stopSessionTimer];
    [self.fab removeFromSuperview]; self.fab = nil;
    [self.panel removeFromSuperview]; self.panel = nil;
}

#pragma mark - 构建面板

- (void)buildPanel {
    UIWindow *w = [MyVoiceResolver anyWindow];
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(w.bounds.size.width - MV_PANEL_W - 12,
                                                         w.bounds.size.height - MV_PANEL_H - 80,
                                                         MV_PANEL_W, MV_PANEL_H)];
    self.panel.backgroundColor = [UIColor clearColor];
    self.panel.layer.cornerRadius = 24;
    self.panel.layer.masksToBounds = YES;
    self.panel.hidden = YES;

    // 液态玻璃底材
    UIVisualEffectView *gv = [MyVoicePanel glassView];
    gv.frame = self.panel.bounds;
    [self.panel addSubview:gv];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)];
    [self.panel addGestureRecognizer:pan];
    [w addSubview:self.panel];

    [self buildHomeView];
    [self buildPickerView];

    [self.panel addSubview:self.homeView];
    [self.panel addSubview:self.pickerView];

    self.homeView.hidden = NO;
    self.pickerView.hidden = YES;
    [self.panel bringSubviewToFront:self.homeView];

    [self refreshVoiceState];
    [self refreshSession];
}

#pragma mark - 主视图

- (void)buildHomeView {
    CGFloat W = MV_PANEL_W;
    self.homeView = [[UIView alloc] initWithFrame:self.panel.bounds];
    self.homeView.backgroundColor = [UIColor clearColor];

    // 顶部高光条
    UIView *hl = [[UIView alloc] initWithFrame:CGRectMake(W*0.08, 0.5, W*0.84, 0.5)];
    hl.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    hl.userInteractionEnabled = NO;
    [self.homeView addSubview:hl];

    // 标题栏（关闭合并到这里）
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(W - 40, 6, 28, 28);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:closeBtn];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 120, 20)];
    title.text = @"我的语音";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithWhite:0 alpha:0.9];
    [self.homeView addSubview:title];

    // 文字输入
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(14, 38, W - 28, 64)];
    self.textView.layer.cornerRadius = 14;
    self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.textColor = [UIColor colorWithWhite:0 alpha:0.85];
    self.textView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.textView.layer.borderWidth = 0.5;
    self.textView.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    self.textView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.homeView addSubview:self.textView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTextViewChanged:)
                                                 name:UITextViewTextDidChangeNotification
                                               object:self.textView];

    // 音色选择（一行）
    self.voiceSelectBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.voiceSelectBtn.frame = CGRectMake(14, 108, W - 28, 40);
    self.voiceSelectBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.voiceSelectBtn.titleLabel.minimumScaleFactor = 0.72;
    self.voiceSelectBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.voiceSelectBtn.layer.cornerRadius = 14;
    self.voiceSelectBtn.layer.borderWidth = 0.5;
    self.voiceSelectBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    self.voiceSelectBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.voiceSelectBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.voiceSelectBtn addTarget:self action:@selector(showPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.voiceSelectBtn];

    // 合成 + 预览并排
    self.sendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.sendBtn.frame = CGRectMake(14, 156, (W - 38) * 0.58, 42);
    [self.sendBtn setTitle:@"合成语音" forState:UIControlStateNormal];
    self.sendBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendBtn.layer.cornerRadius = 16;
    self.sendBtn.clipsToBounds = YES;
    // 蓝液态玻璃
    CAGradientLayer *sg = [CAGradientLayer layer];
    sg.frame = CGRectMake(0, 0, self.sendBtn.frame.size.width, 42);
    sg.colors = @[(id)[UIColor colorWithRed:0 green:0.42 blue:0.95 alpha:1].CGColor,
                  (id)[UIColor colorWithRed:0.25 green:0.55 blue:1 alpha:1].CGColor];
    sg.startPoint = CGPointMake(0, 0);
    sg.endPoint = CGPointMake(0.8, 1);
    [self.sendBtn.layer insertSublayer:sg atIndex:0];
    self.sendBtn.layer.borderWidth = 0.5;
    self.sendBtn.layer.borderColor = [UIColor clearColor].CGColor;
    UIView *shl = [[UIView alloc] initWithFrame:CGRectMake(2, 1, self.sendBtn.frame.size.width - 4, 18)];
    shl.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    shl.userInteractionEnabled = NO;
    shl.layer.cornerRadius = 14;
    [self.sendBtn addSubview:shl];
    [self.sendBtn addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.sendBtn];

    self.previewBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.previewBtn.frame = CGRectMake(14 + (W - 38) * 0.58 + 10, 156, (W - 38) * 0.42 - 10, 42);
    [self.previewBtn setTitle:@"预览" forState:UIControlStateNormal];
    self.previewBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [self.previewBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.65] forState:UIControlStateNormal];
    self.previewBtn.layer.cornerRadius = 16;
    self.previewBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.previewBtn.layer.borderWidth = 0.5;
    self.previewBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    UIView *phl = [[UIView alloc] initWithFrame:CGRectMake(2, 1, self.previewBtn.frame.size.width - 4, 16)];
    phl.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    phl.userInteractionEnabled = NO;
    [self.previewBtn addSubview:phl];
    [self.previewBtn addTarget:self action:@selector(onPreview) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.previewBtn];

    // 音色管理（独立一行短标题）
    self.cloneBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.cloneBtn.frame = CGRectMake(14, 206, W - 28, 40);
    [self.cloneBtn setTitle:@"＋ 音色管理" forState:UIControlStateNormal];
    self.cloneBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self.cloneBtn setTitleColor:[UIColor colorWithRed:0 green:0.42 blue:0.95 alpha:1] forState:UIControlStateNormal];
    self.cloneBtn.layer.cornerRadius = 14;
    self.cloneBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.cloneBtn.layer.borderWidth = 0.5;
    self.cloneBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    [self.cloneBtn addTarget:self action:@selector(onClone) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.cloneBtn];

    // 会话状态（绿点 + 文字）
    self.sessionLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 252, W - 32, 18)];
    self.sessionLabel.font = [UIFont systemFontOfSize:11];
    self.sessionLabel.textColor = [UIColor colorWithWhite:0 alpha:0.3];
    self.sessionLabel.userInteractionEnabled = YES;
    [self.sessionLabel addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(refreshSession)]];
    [self.homeView addSubview:self.sessionLabel];
}

- (void)refreshVoiceState {
    self.allVoices = [self voiceList];
    self.filteredVoices = self.allVoices;
    NSUInteger nQwen = 0, nMine = 0;
    for (NSDictionary *d in self.allVoices)
        ([d[@"provider"] integerValue] == 1) ? nQwen++ : nMine++;
    if (self.sectionLabel) {
        self.sectionLabel.text = [NSString stringWithFormat:
            @"千问 %lu 个 · 我的 %lu 个", (unsigned long)nQwen, (unsigned long)nMine];
    }
    NSString *vid = (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
    self.selectedVoiceID = vid;

    NSString *name = @"未选择音色";
    for (NSDictionary *d in self.allVoices) {
        if ([d[@"voiceID"] isEqualToString:vid]) { name = d[@"name"] ?: d[@"voiceID"]; break; }
    }
    NSString *provider = (MVTTSProvider() == 1) ? @"千问" : @"CV";
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"音色  "] attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:13], NSForegroundColorAttributeName:[UIColor colorWithWhite:0 alpha:0.35]}];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:name attributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:14], NSForegroundColorAttributeName:[UIColor colorWithWhite:0 alpha:0.85]}]];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ›" attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12], NSForegroundColorAttributeName:[UIColor colorWithWhite:0 alpha:0.2]}]];
    [self.voiceSelectBtn setAttributedTitle:attr forState:UIControlStateNormal];
    if (self.voiceTable) [self.voiceTable reloadData];
}

#pragma mark - 音色选择视图

- (void)buildPickerView {
    CGFloat W = MV_PANEL_W;
    CGFloat H = MV_PANEL_H;
    self.pickerView = [[UIView alloc] initWithFrame:self.panel.bounds];
    self.pickerView.backgroundColor = [UIColor clearColor];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 32)];
    UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(14, 6, W - 160, 20)];
    pt.text = @"选择音色";
    pt.font = [UIFont boldSystemFontOfSize:15];
    pt.textColor = [UIColor colorWithWhite:0 alpha:0.9];
    [header addSubview:pt];

    self.reloadBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.reloadBtn setTitle:@"刷新" forState:UIControlStateNormal];
    self.reloadBtn.frame = CGRectMake(W - 68, 5, 54, 24);
    self.reloadBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [self.reloadBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.5] forState:UIControlStateNormal];
    [self.reloadBtn addTarget:self action:@selector(onReloadVoices) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.reloadBtn];

    self.pickerBackBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pickerBackBtn setTitle:@"返回" forState:UIControlStateNormal];
    self.pickerBackBtn.frame = CGRectMake(W - 128, 5, 52, 24);
    self.pickerBackBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [self.pickerBackBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.5] forState:UIControlStateNormal];
    [self.pickerBackBtn addTarget:self action:@selector(hidePicker) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.pickerBackBtn];
    [self.pickerView addSubview:header];

    CGFloat y = 34;
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(10, y, W - 20, 26)];
    self.searchBar.placeholder = @"搜索音色…";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.delegate = self;
    self.searchBar.barTintColor = [UIColor clearColor];
    self.searchBar.tintColor = [UIColor colorWithWhite:0 alpha:0.5];
    [self.pickerView addSubview:self.searchBar];
    y += 30;

    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 36, 18)];
    sl.text = @"语速";
    sl.font = [UIFont systemFontOfSize:11];
    sl.textColor = [UIColor colorWithWhite:0 alpha:0.4];
    [self.pickerView addSubview:sl];
    self.speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(52, y, W - 126, 18)];
    self.speedSlider.minimumValue = 0.5f;
    self.speedSlider.maximumValue = 2.0f;
    self.speedSlider.value = (float)MVQwenSpeed();
    [self.speedSlider addTarget:self action:@selector(onSpeedChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerView addSubview:self.speedSlider];
    self.speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(W - 66, y, 52, 18)];
    self.speedLabel.font = [UIFont systemFontOfSize:11];
    self.speedLabel.textAlignment = NSTextAlignmentRight;
    self.speedLabel.textColor = [UIColor colorWithWhite:0 alpha:0.5];
    [self updateSpeedLabel];
    [self.pickerView addSubview:self.speedLabel];
    y += 20;

    UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 36, 18)];
    el.text = @"语气";
    el.font = [UIFont systemFontOfSize:11];
    el.textColor = [UIColor colorWithWhite:0 alpha:0.4];
    [self.pickerView addSubview:el];
    self.emotionSeg = [[UISegmentedControl alloc] initWithItems:@[@"默认", @"生气", @"愤怒", @"快乐", @"开朗"]];
    self.emotionSeg.frame = CGRectMake(52, y, W - 66, 22);
    self.emotionSeg.selectedSegmentIndex = [self emotionIndex:MVQwenEmotion()];
    [self.emotionSeg addTarget:self action:@selector(onEmotionChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerView addSubview:self.emotionSeg];
    y += 24;

    self.sectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, W - 28, 14)];
    NSUInteger nQwen = 0, nMine = 0;
    for (NSDictionary *d in self.allVoices)
        ([d[@"provider"] integerValue] == 1) ? nQwen++ : nMine++;
    self.sectionLabel.text = [NSString stringWithFormat:
        @"千问 %lu 个 · 我的 %lu 个", (unsigned long)nQwen, (unsigned long)nMine];
    self.sectionLabel.font = [UIFont boldSystemFontOfSize:12];
    self.sectionLabel.textColor = [UIColor colorWithWhite:0 alpha:0.6];
    [self.pickerView addSubview:self.sectionLabel];
    y += 16;

    self.voiceTable = [[UITableView alloc] initWithFrame:CGRectMake(12, y, W - 24, H - y - 8) style:UITableViewStylePlain];
    self.voiceTable.backgroundColor = [UIColor clearColor];
    self.voiceTable.dataSource = self;
    self.voiceTable.delegate = self;
    self.voiceTable.rowHeight = 34;
    self.voiceTable.layer.cornerRadius = 12;
    self.voiceTable.separatorInset = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.pickerView addSubview:self.voiceTable];

    UILongPressGestureRecognizer *lpDel = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onVoiceLongPress:)];
    lpDel.minimumPressDuration = 0.6;
    [self.voiceTable addGestureRecognizer:lpDel];
}

- (NSInteger)emotionIndex:(NSString*)emotion {
    NSDictionary *map = @{@"default":@0, @"生气":@1, @"angry":@1, @"愤怒":@2, @"快乐":@3, @"happy":@3, @"开朗":@4, @"cheerful":@4};
    return [map[emotion] integerValue];
}
- (NSString*)emotionValueForIndex:(NSInteger)idx {
    NSArray *arr = @[@"default", @"生气", @"愤怒", @"快乐", @"开朗"];
    return arr[idx];
}
- (void)updateSpeedLabel { self.speedLabel.text = [NSString stringWithFormat:@"%.2fx", self.speedSlider.value]; }
- (void)onSpeedChanged:(UISlider*)s { [self updateSpeedLabel]; MVSetShared(@"qwenSpeed", @(s.value)); }
- (void)onEmotionChanged:(UISegmentedControl*)seg { MVSetShared(@"qwenEmotion", [self emotionValueForIndex:seg.selectedSegmentIndex]); }
- (void)onReloadVoices { [self refreshVoiceState]; [self.voiceTable reloadData]; [[MyVoiceManager shared] toast:@"已刷新"]; }
- (void)showPicker { self.homeView.hidden = YES; self.pickerView.hidden = NO; [self refreshVoiceState]; [self.searchBar resignFirstResponder]; }
- (void)hidePicker { self.pickerView.hidden = YES; self.homeView.hidden = NO; [self refreshVoiceState]; }

#pragma mark - 搜索
- (void)searchBar:(UISearchBar*)searchBar textDidChange:(NSString*)searchText {
    NSString *q = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    if (!q.length) { self.filteredVoices = self.allVoices; }
    else {
        NSMutableArray *arr = [NSMutableArray array];
        for (NSDictionary *d in self.allVoices) {
            NSString *name = [d[@"name"] ?: @"" lowercaseString];
            NSString *vid = [d[@"voiceID"] ?: @"" lowercaseString];
            if ([name containsString:q] || [vid containsString:q]) [arr addObject:d];
        }
        self.filteredVoices = arr;
    }
    [self.voiceTable reloadData];
}
- (void)searchBarSearchButtonClicked:(UISearchBar*)searchBar { [searchBar resignFirstResponder]; }

#pragma mark - UITableView
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.filteredVoices.count;
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    static NSString *cid = @"mvVoiceCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.textLabel.textColor = [UIColor colorWithWhite:0 alpha:0.85];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0 alpha:0.25];
    }
    NSDictionary *d = self.filteredVoices[(NSUInteger)indexPath.row];
    cell.textLabel.text = d[@"name"] ?: d[@"voiceID"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
        ([d[@"provider"] integerValue] == 1) ? @"千问" : @"克隆", d[@"model"] ?: @""];
    cell.accessoryType = [d[@"voiceID"] isEqualToString:self.selectedVoiceID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor colorWithWhite:0 alpha:0.6];
    return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.filteredVoices[(NSUInteger)indexPath.row];
    self.selectedVoiceID = d[@"voiceID"];
    if ([d[@"provider"] integerValue] == 1) {
        MVSetShared(@"ttsProvider", @1);
        MVSetShared(@"qwenVoice", self.selectedVoiceID);
        MVSetShared(@"qwenModel", d[@"model"] ?: @"qwen3-tts-flash");
    } else {
        MVSetShared(@"ttsProvider", @0);
        MVSetShared(@"currentVoiceID", self.selectedVoiceID);
    }
    [self.voiceTable reloadData];
    [self hidePicker];
}
- (void)onVoiceLongPress:(UILongPressGestureRecognizer*)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:self.voiceTable];
    NSIndexPath *ip = [self.voiceTable indexPathForRowAtPoint:p];
    if (!ip || ip.row >= (NSInteger)self.filteredVoices.count) return;
    NSDictionary *d = self.filteredVoices[(NSUInteger)ip.row];
    if ([d[@"provider"] integerValue] == 1) { [[MyVoiceManager shared] toast:@"千问预置不可删"]; return; }
    NSString *vid = d[@"voiceID"] ?: @"";
    NSString *name = d[@"name"] ?: vid;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除音色"
        message:[NSString stringWithFormat:@"确定从列表删除「%@」吗？", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
        NSMutableArray *keep = [NSMutableArray array];
        for (NSDictionary *x in MVVoices())
            if (![x[@"voiceID"] isEqualToString:vid]) [keep addObject:x];
        MVSetShared(@"voices", keep);
        if ([MVCurrentVoiceID() isEqualToString:vid]) {
            NSString *next = ((NSDictionary*)keep.firstObject)[@"voiceID"] ?: @"";
            MVSetShared(@"currentVoiceID", next);
        }
        [self refreshVoiceState];
        [self.voiceTable reloadData];
        [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已删除「%@」", name]];
    }]];
    UIViewController *top = [MyVoiceResolver anyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 会话/拖动
- (void)refreshSession {
    NSString *s = [[MyVoiceManager shared] talkerStatus];
    BOOL ok = [s rangeOfString:@"未识别"].location == NSNotFound;
    self.sessionLabel.text = [NSString stringWithFormat:@"%@  %@", ok ? @"●" : @"○", ok ? @"已连接" : @"未识别"];
    self.sessionLabel.textColor = ok ? [UIColor colorWithWhite:0 alpha:0.35] : [UIColor colorWithWhite:0 alpha:0.2];
}
- (void)startSessionTimer {
    if (self.sessionTimer) return;
    self.sessionTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refreshSession) userInfo:nil repeats:YES];
}
- (void)stopSessionTimer { [self.sessionTimer invalidate]; self.sessionTimer = nil; }

- (void)dragPanel:(UIPanGestureRecognizer*)g {
    UIView *host = self.panel.superview;
    if (!host) return;
    CGPoint t = [g translationInView:host];
    CGRect f = self.panel.frame;
    f.origin.x += t.x; f.origin.y += t.y;
    CGFloat maxX = host.bounds.size.width - f.size.width;
    CGFloat maxY = host.bounds.size.height - f.size.height;
    f.origin.x = MAX(0, MIN(MAX(0, maxX), f.origin.x));
    f.origin.y = MAX(0, MIN(MAX(0, maxY), f.origin.y));
    self.panel.frame = f;
    [g setTranslation:CGPointZero inView:host];
}
- (void)togglePanel {
    if (!MVUnlocked()) { MVShowLicenseAlert(); return; }
    self.panel.hidden = !self.panel.hidden;
    if (self.panel.hidden) { [self stopSessionTimer]; }
    else { [self refreshSession]; [self refreshVoiceState]; [self startSessionTimer]; }
}
- (void)closePanel { self.panel.hidden = YES; [self stopSessionTimer]; }

#pragma mark - 发送/预览/克隆
- (NSString*)resolvedVoiceID {
    NSString *vid = self.selectedVoiceID;
    if (vid.length) return vid;
    return (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
}

#pragma mark - 预合成
- (void)onTextViewChanged:(NSNotification*)n {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(prewarmNow) object:nil];
    [self performSelector:@selector(prewarmNow) withObject:nil afterDelay:0.35];
}
- (void)prewarmNow {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || text.length > 300) return;
    [[MyVoiceCloud shared] prewarmText:text voiceID:[self resolvedVoiceID]];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

#pragma mark - 发送
- (void)onSend {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    NSString *vid = [self resolvedVoiceID];
    NSDictionary *sel = [self selectedEntry];
    if (MVEngineMode()==1 && !vid.length) {
        [[MyVoiceManager shared] toast:@"请先在音色列表选择音色"];
        return;
    }
    if (MVEngineMode()==1 && sel && [sel[@"provider"] integerValue]==0 && MVTTSProvider()==0) {
        MVSetShared(@"currentVoiceID", vid);
    }
    [[MyVoiceManager shared] handleSendText:text];
    self.panel.hidden = YES;
    [self stopSessionTimer];
}
- (void)onPreview {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    [MyVoiceEngine previewText:text voiceID:[self resolvedVoiceID]];
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
    if (g.state == UIGestureRecognizerStateEnded) {
        // ★ 2.7.1：松手后自动吸附到最近的屏幕左/右边缘
        CGFloat cx = CGRectGetMidX(f);
        CGFloat targetX = (cx < w.bounds.size.width / 2) ? 4 : w.bounds.size.width - f.size.width - 4;
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ self.fab.frame = CGRectMake(targetX, f.origin.y, f.size.width, f.size.height); }
                         completion:nil];
    }
}

@end
