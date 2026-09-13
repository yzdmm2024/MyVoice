#import "MyVoicePanel.h"
#import "MyVoiceCommon.h"
#import "MyVoiceEngine.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceCloneController.h"
#import "MyVoiceCloud.h"
#import <UIKit/UIKit.h>

#define MV_PANEL_W 320.0
#define MV_PANEL_H 360.0
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
@property (nonatomic, strong) UILabel *toneLabel;
@property (nonatomic, strong) UIScrollView *styleScroll;
@property (nonatomic, strong) NSArray *styleButtons;
@property (nonatomic, strong) UISlider *pitchSlider;
@property (nonatomic, strong) UILabel *pitchLabel;
@property (nonatomic, strong) UILabel *pitchValueLabel;
@property (nonatomic, strong) UIButton *polishBtn;
@property (nonatomic, strong) UILabel *pickerHintLabel;
@property (nonatomic, strong) UILabel *sectionLabel;
@property (nonatomic, strong) UITableView *voiceTable;
@property (nonatomic, strong) UIButton *reloadBtn;
@property (nonatomic, strong) UIButton *pickerBackBtn;
@property (nonatomic, strong) NSArray *allVoices;
@property (nonatomic, strong) NSArray *filteredVoices;
@property (nonatomic, strong) NSString *selectedVoiceID;
@property (nonatomic, strong) UIButton *dialectBtn;
@property (nonatomic, strong) UIButton *instrBtn;
@property (nonatomic, strong) NSArray *voiceSections;
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
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(14, 36, W - 28, 84)];
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

    // ★ 2.8.5：文本一键纠偏（数字读法 / 标点 / 断句 / 符号），点一下改"该怎么念"
    self.polishBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.polishBtn.frame = CGRectMake(14, 126, W - 28, 30);
    [self.polishBtn setTitle:@"✨ 一键纠偏（数字 · 标点 · 断句）" forState:UIControlStateNormal];
    self.polishBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    [self.polishBtn setTitleColor:[UIColor colorWithRed:0 green:0.42 blue:0.95 alpha:1]
                         forState:UIControlStateNormal];
    self.polishBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.polishBtn.layer.cornerRadius = 12;
    self.polishBtn.layer.borderWidth = 0.5;
    self.polishBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    [self.polishBtn addTarget:self action:@selector(onPolish) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.polishBtn];

    // 音色选择（一行）
    self.voiceSelectBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.voiceSelectBtn.frame = CGRectMake(14, 164, W - 28, 40);
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
    self.sendBtn.frame = CGRectMake(14, 212, (W - 38) * 0.58, 42);
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
    self.previewBtn.frame = CGRectMake(14 + (W - 38) * 0.58 + 10, 212, (W - 38) * 0.42 - 10, 42);
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
    self.cloneBtn.frame = CGRectMake(14, 262, W - 28, 40);
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
    self.sessionLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 312, W - 32, 18)];
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
    [self rebuildVoiceSections];                    // ★ 2.8.6：分节
    NSUInteger nQwen = 0, nMine = 0;
    for (NSDictionary *d in self.allVoices)
        ([d[@"provider"] integerValue] == 1) ? nQwen++ : nMine++;
    if (self.sectionLabel) {
        // ★ 2.8.6：状态行顺带告诉你"当前音色还能说几种方言"——
        //   方言能力由音色绑定的模型决定，这是最容易踩空的地方。
        NSArray *dl = (MVTTSProvider() == 0)
            ? MVDialectListForModel(MVModelForVoice(MVCurrentVoiceID())) : @[];
        self.sectionLabel.text = dl.count
            ? [NSString stringWithFormat:@"千问 %lu · 我的 %lu · 当前音色可 %lu 种方言",
               (unsigned long)nQwen, (unsigned long)nMine, (unsigned long)dl.count]
            : [NSString stringWithFormat:@"千问 %lu 个 · 我的 %lu 个",
               (unsigned long)nQwen, (unsigned long)nMine];
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

    // ★ 2.8.5：把当前 provider 对应的参数回填到控件，并按 provider 重新摆位
    BOOL cosy = (MVTTSProvider() == 0);
    if (self.speedSlider)     self.speedSlider.value = cosy ? (float)MVCosyRate() : (float)MVQwenSpeed();
    if (self.speedLabel)      [self updateSpeedLabel];
    if (self.pitchSlider)     self.pitchSlider.value = (float)MVCosyPitch();
    if (self.pitchValueLabel) [self updatePitchLabel];
    if (self.emotionSeg)      self.emotionSeg.selectedSegmentIndex = [self emotionIndex:MVQwenEmotion()];
    [self updateStyleButtons];
    [self updateDialectButtons];                    // ★ 2.8.6
    [self layoutPickerRows];
}

#pragma mark - ★ 2.8.6 方言 / 自定义指令 / 分节

// 音色列表分节：千问预置一大坨 + 我的克隆搅在一起，36 个平铺根本找不到自己的音色
- (void)rebuildVoiceSections {
    NSMutableArray *qwen = [NSMutableArray array], *mine = [NSMutableArray array];
    for (NSDictionary *d in self.filteredVoices) {
        ([d[@"provider"] integerValue] == 1) ? [qwen addObject:d] : [mine addObject:d];
    }
    NSMutableArray *secs = [NSMutableArray array];
    if (qwen.count) [secs addObject:@{@"title": [NSString stringWithFormat:@"千问预置 · %lu", (unsigned long)qwen.count],
                                      @"items": qwen}];
    if (mine.count) [secs addObject:@{@"title": [NSString stringWithFormat:@"我的克隆 · %lu", (unsigned long)mine.count],
                                      @"items": mine}];
    self.voiceSections = secs;
}

- (NSDictionary*)voiceAt:(NSIndexPath*)ip {
    if (ip.section < 0 || ip.section >= (NSInteger)self.voiceSections.count) return nil;
    NSArray *items = self.voiceSections[(NSUInteger)ip.section][@"items"];
    if (ip.row < 0 || ip.row >= (NSInteger)items.count) return nil;
    return items[(NSUInteger)ip.row];
}

- (void)updateDialectButtons {
    if (!self.dialectBtn) return;
    NSString *d = MVGetStr(@"cosyDialect");
    [self.dialectBtn setTitle:(d.length ? [NSString stringWithFormat:@"方言：%@", d] : @"方言")
                     forState:UIControlStateNormal];
    NSString *inst = MVGetStr(@"cosyInstruction");
    BOOL custom = (inst.length > 0) && (d.length == 0);
    [self.instrBtn setTitle:(custom ? @"指令：已自定义" : @"自定义指令")
                   forState:UIControlStateNormal];
}

// 方言：只有「当前音色绑定的模型」支持的那些才列出来
- (void)onDialectTap {
    NSString *model = MVModelForVoice(MVCurrentVoiceID());
    NSArray *ds = MVDialectListForModel(model);
    if (!ds.count) {
        [[MyVoiceManager shared] toast:@"该音色的模型不支持方言（复刻时选 v3/Qwen 模型即可）"];
        return;
    }
    BOOL isQwen = [model hasPrefix:@"qwen-audio-3.0-tts"];
    NSString *msg = [NSString stringWithFormat:
        @"%@ 支持以下方言。\n方言靠合成指令实现，不需要重新克隆。%@",
        model, isQwen ? @"（含湖南话、重庆话）" : @""];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选方言"
        message:msg preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *cur = MVGetStr(@"cosyDialect");
    for (NSString *d in ds) {
        NSString *title = [d isEqualToString:cur] ? [@"✓ " stringByAppendingString:d] : d;
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                MVSetShared(@"cosyDialect", d);
                // 「普通话」= 清掉方言指令，回到模型默认读数
                MVSetShared(@"cosyInstruction", MVDialectInstruction(d) ?: @"");
                [self updateDialectButtons];
                [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已设为%@", d]];
            }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.dialectBtn;
    ac.popoverPresentationController.sourceRect = self.dialectBtn.bounds;
    UIViewController *top = [MyVoiceResolver anyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}

// 自定义指令：改的是语气/情绪/语速/角色，不是口音（口音请用左边的方言）
- (void)onInstructionTap {
    NSString *cur = MVGetStr(@"cosyInstruction");
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自定义指令"
        message:@"用一句自然语言描述"怎么念"，最多 100 字符。\n"
                 "例：用慵懒随意的语气说，语速慢一点，句尾别拖长。\n"
                 "注意：这改的是语气/情绪/语速，改不了口音 —— 方言请用左边的「方言」。"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.text = cur;
        tf.placeholder = @"语气 / 情绪 / 语速 / 角色";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a){
            MVSetShared(@"cosyInstruction", @"");
            MVSetShared(@"cosyDialect", @"");
            [self updateDialectButtons];
            [[MyVoiceManager shared] toast:@"已清空指令"];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){
            NSString *t = [ac.textFields.firstObject.text
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length > 100) t = [t substringToIndex:100];   // 官方 instruction 上限 100 字符
            MVSetShared(@"cosyInstruction", t ?: @"");
            MVSetShared(@"cosyDialect", @"");                   // 自定义优先，清掉方言高亮
            [self updateDialectButtons];
            [[MyVoiceManager shared] toast:t.length ? @"已保存指令" : @"已清空指令"];
        }]];
    UIViewController *top = [MyVoiceResolver anyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
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

    // ★ 2.8.5：这一行按 provider 换内容 ——
    //   千问 = 「语气」段控；克隆 = 「一键风格」胶囊（默认/人情味/标准腔/慢语速/亲切/活泼）
    self.toneLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y + 3, 36, 18)];
    self.toneLabel.text = @"语气";
    self.toneLabel.font = [UIFont systemFontOfSize:11];
    self.toneLabel.textColor = [UIColor colorWithWhite:0 alpha:0.4];
    [self.pickerView addSubview:self.toneLabel];

    self.emotionSeg = [[UISegmentedControl alloc] initWithItems:@[@"默认", @"生气", @"愤怒", @"快乐", @"开朗"]];
    self.emotionSeg.frame = CGRectMake(52, y, W - 66, 22);
    self.emotionSeg.selectedSegmentIndex = [self emotionIndex:MVQwenEmotion()];
    [self.emotionSeg addTarget:self action:@selector(onEmotionChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerView addSubview:self.emotionSeg];

    self.styleScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, y, W - 24, 26)];
    self.styleScroll.showsHorizontalScrollIndicator = NO;
    self.styleScroll.alwaysBounceHorizontal = YES;
    NSArray *styleNames = MVCosyStyleNames();
    NSMutableArray *styleBtns = [NSMutableArray array];
    CGFloat bx = 0;
    for (NSUInteger i = 0; i < styleNames.count; i++) {
        NSString *t = styleNames[i];
        CGFloat bw = [t sizeWithAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12]}].width + 18;
        UIButton *sb = [UIButton buttonWithType:UIButtonTypeCustom];
        sb.frame = CGRectMake(bx, 1, bw, 24);
        [sb setTitle:t forState:UIControlStateNormal];
        sb.titleLabel.font = [UIFont systemFontOfSize:12];
        sb.tag = 2000 + (NSInteger)i;
        sb.layer.cornerRadius = 12;
        sb.layer.borderWidth = 0.5;
        [sb addTarget:self action:@selector(onStyleTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.styleScroll addSubview:sb];
        [styleBtns addObject:sb];
        bx += bw + 6;
    }
    self.styleScroll.contentSize = CGSizeMake(bx, 26);
    self.styleButtons = styleBtns;
    [self.pickerView addSubview:self.styleScroll];

    // 音高（仅克隆音色可见；千问分支摆位时隐藏）
    self.pitchLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 36, 18)];
    self.pitchLabel.text = @"音高";
    self.pitchLabel.font = [UIFont systemFontOfSize:11];
    self.pitchLabel.textColor = [UIColor colorWithWhite:0 alpha:0.4];
    [self.pickerView addSubview:self.pitchLabel];
    self.pitchSlider = [[UISlider alloc] initWithFrame:CGRectMake(52, y, W - 126, 18)];
    self.pitchSlider.minimumValue = 0.5f;
    self.pitchSlider.maximumValue = 2.0f;
    self.pitchSlider.value = (float)MVCosyPitch();
    [self.pitchSlider addTarget:self action:@selector(onPitchChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerView addSubview:self.pitchSlider];
    self.pitchValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(W - 66, y, 52, 18)];
    self.pitchValueLabel.font = [UIFont systemFontOfSize:11];
    self.pitchValueLabel.textAlignment = NSTextAlignmentRight;
    self.pitchValueLabel.textColor = [UIColor colorWithWhite:0 alpha:0.5];
    [self updatePitchLabel];
    [self.pickerView addSubview:self.pitchValueLabel];

    // ★ 2.8.6：方言 / 自定义指令（只对克隆音色有意义）
    //   声音复刻只学「声线」不学口音 —— 想让克隆音色说方言，只能靠合成时的 instruction。
    //   所以这里把"方言"做成一次点击（写一句「请用X话说这句话。」），而不是让用户自己憋 prompt。
    self.dialectBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.dialectBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [self.dialectBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.8] forState:UIControlStateNormal];
    self.dialectBtn.layer.cornerRadius = 12;
    self.dialectBtn.layer.borderWidth = 0.5;
    self.dialectBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.15].CGColor;
    self.dialectBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.05];
    [self.dialectBtn addTarget:self action:@selector(onDialectTap) forControlEvents:UIControlEventTouchUpInside];
    [self.pickerView addSubview:self.dialectBtn];

    self.instrBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.instrBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [self.instrBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.8] forState:UIControlStateNormal];
    self.instrBtn.layer.cornerRadius = 12;
    self.instrBtn.layer.borderWidth = 0.5;
    self.instrBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.15].CGColor;
    self.instrBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.05];
    [self.instrBtn addTarget:self action:@selector(onInstructionTap) forControlEvents:UIControlEventTouchUpInside];
    [self.pickerView addSubview:self.instrBtn];

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

    [self updateStyleButtons];      // ★ 2.8.5
    [self layoutPickerRows];        // ★ 2.8.5：按当前 provider 摆位（音高行仅克隆可见）
}

// ★ 2.8.5：选择音色页下半部分按 provider 动态摆位。
//   千问不支持 instruction/音高 → 隐藏音高行，把音色表格往上提，多露一行。
- (void)layoutPickerRows {
    CGFloat W = MV_PANEL_W, H = MV_PANEL_H;
    BOOL cosy = (MVTTSProvider() == 0);

    self.toneLabel.text = cosy ? @"风格" : @"语气";
    self.emotionSeg.hidden = cosy;
    self.styleScroll.hidden = !cosy;

    // 当前音色的模型不支持 instruction（cosyvoice-v2 / v1）时把风格条置灰 ——
    // 合成代码里已按模型跳过该参数（传了会 400），这里同步提示用户"这个音色用不了风格"。
    BOOL styleOK = cosy ? MVCosySupportsInstruction(MVModelForVoice(MVCurrentVoiceID())) : YES;
    self.styleScroll.alpha = styleOK ? 1.0 : 0.35;
    self.styleScroll.userInteractionEnabled = styleOK;

    CGFloat y = 84;                                        // 语气 / 风格行
    self.toneLabel.frame   = CGRectMake(14, y + 3, 36, 18);
    self.emotionSeg.frame  = CGRectMake(52, y, W - 66, 22);
    self.styleScroll.frame = CGRectMake(12, y, W - 24, 26);
    y += 26;

    self.pitchLabel.hidden      = !cosy;                   // 音高行（仅克隆）
    self.pitchSlider.hidden     = !cosy;
    self.pitchValueLabel.hidden = !cosy;
    if (cosy) {
        self.pitchLabel.frame      = CGRectMake(14, y, 36, 18);
        self.pitchSlider.frame     = CGRectMake(52, y, W - 126, 18);
        self.pitchValueLabel.frame = CGRectMake(W - 66, y, 52, 18);
        y += 20;
    }

    // ★ 2.8.6：方言 / 自定义指令行（仅克隆音色；千问不认 instruction）
    self.dialectBtn.hidden = !cosy;
    self.instrBtn.hidden   = !cosy;
    if (cosy) {
        CGFloat half = (W - 30) / 2;
        self.dialectBtn.frame = CGRectMake(12, y, half, 26);
        self.instrBtn.frame   = CGRectMake(12 + half + 6, y, half, 26);
        y += 30;
    }
    [self updateDialectButtons];

    self.sectionLabel.frame = CGRectMake(14, y, W - 28, 14);
    y += 16;
    self.voiceTable.frame = CGRectMake(12, y, W - 24, H - y - 8);
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
// ★ 2.8.5：语速滑块以前只写 qwenSpeed，克隆分支根本不读 → 用克隆音色时它是个摆设。
//   现在按 provider 分流落到各自的键，两个 provider 都真正生效。
- (void)onSpeedChanged:(UISlider*)s {
    [self updateSpeedLabel];
    if (MVTTSProvider() == 1) MVSetShared(@"qwenSpeed", @(s.value));
    else                      MVSetShared(@"cosyRate",  @(s.value));
}
- (void)onEmotionChanged:(UISegmentedControl*)seg { MVSetShared(@"qwenEmotion", [self emotionValueForIndex:seg.selectedSegmentIndex]); }

// ★ 2.8.5：一键风格 —— 落到 CosyVoice 的 instruction（这是"去 AI 味"最有效的旋钮）
- (void)onStyleTap:(UIButton*)b {
    NSInteger idx = b.tag - 2000;
    MVSetShared(@"cosyStyle", @(idx));
    MVSetShared(@"cosyInstruction", @"");          // 选预设时清掉自定义指令，避免互相覆盖
    // 一键 = 一步到位：连该风格推荐的语速一起调过去（否则"慢语速"只靠指令，听不出明显差别）
    double rec = MVCosyStyleRate(idx);
    if (rec > 0.01) {
        MVSetShared(@"cosyRate", @(rec));
        self.speedSlider.value = (float)rec;
        [self updateSpeedLabel];
    }
    [self updateStyleButtons];
    [MyVoiceCloud clearSynthesisCache];
    [self prewarmNow];
    NSArray *names = MVCosyStyleNames();
    NSString *nm = (idx >= 0 && idx < (NSInteger)names.count) ? names[(NSUInteger)idx] : @"默认";
    [[MyVoiceManager shared] toast:rec > 0.01
        ? [NSString stringWithFormat:@"风格：%@（语速 %.2fx）", nm, rec]
        : [NSString stringWithFormat:@"风格：%@", nm]];
}
- (void)updateStyleButtons {
    NSInteger cur = MVCosyStyle();
    for (UIButton *b in self.styleButtons) {
        BOOL on = (b.tag - 2000) == cur;
        b.backgroundColor = on ? [UIColor colorWithRed:0 green:0.42 blue:0.95 alpha:0.9]
                               : [UIColor colorWithWhite:0 alpha:0.05];
        b.layer.borderColor = on ? [UIColor clearColor].CGColor
                                 : [UIColor colorWithWhite:0 alpha:0.08].CGColor;
        [b setTitleColor:(on ? [UIColor whiteColor] : [UIColor colorWithWhite:0 alpha:0.5])
                forState:UIControlStateNormal];
    }
}
- (void)updatePitchLabel { self.pitchValueLabel.text = [NSString stringWithFormat:@"%.2fx", self.pitchSlider.value]; }
- (void)onPitchChanged:(UISlider*)s { [self updatePitchLabel]; MVSetShared(@"cosyPitch", @(s.value)); }

// ★ 2.8.5：文本一键纠偏 —— TTS 对阿拉伯数字/英符号/无标点长句念得怪，书面写法也加重 AI 味
- (void)onPolish {
    NSString *src = self.textView.text ?: @"";
    if (!src.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    NSMutableArray *notes = [NSMutableArray array];
    NSString *dst = MVTextPolish(src, notes);
    if ([dst isEqualToString:src]) {
        [[MyVoiceManager shared] toast:@"已经很规整，无需纠偏"];
        return;
    }
    self.textView.text = dst;                      // 会触发 TextDidChange → 自动预合成
    [[MyVoiceManager shared] toast:notes.count
        ? [NSString stringWithFormat:@"已纠偏：%@", [notes componentsJoinedByString:@"、"]]
        : @"已纠偏"];
}
- (void)onReloadVoices { [self refreshVoiceState]; [self.voiceTable reloadData]; [[MyVoiceManager shared] toast:@"已刷新"]; }
- (void)showPicker { self.homeView.hidden = YES; self.pickerView.hidden = NO; [self refreshVoiceState]; [self layoutPickerRows]; [self.searchBar resignFirstResponder]; }
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
    [self rebuildVoiceSections];                    // ★ 2.8.6
    [self.voiceTable reloadData];
}
- (void)searchBarSearchButtonClicked:(UISearchBar*)searchBar { [searchBar resignFirstResponder]; }

#pragma mark - UITableView
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return (NSInteger)self.voiceSections.count;     // ★ 2.8.6：千问 / 克隆 分节
}
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.voiceSections.count) return nil;
    return self.voiceSections[(NSUInteger)section][@"title"];
}
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.voiceSections.count) return 0;
    return (NSInteger)[self.voiceSections[(NSUInteger)section][@"items"] count];
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
    NSDictionary *d = [self voiceAt:indexPath];
    if (!d) return [[UITableViewCell alloc] init];
    cell.textLabel.text = d[@"name"] ?: d[@"voiceID"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
        ([d[@"provider"] integerValue] == 1) ? @"千问" : @"克隆", d[@"model"] ?: @""];
    cell.accessoryType = [d[@"voiceID"] isEqualToString:self.selectedVoiceID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor colorWithWhite:0 alpha:0.6];
    return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = [self voiceAt:indexPath];
    if (!d) return;
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
    if (!ip) return;
    NSDictionary *d = [self voiceAt:ip];
    if (!d) return;
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
