#import "MyVoicePanel.h"
#import "MyVoiceCommon.h"
#import "MyVoiceEngine.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceCloneController.h"
#import "MyVoiceCloud.h"
#import "MyVoiceBuiltin.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>   // ★ 2.8.7：列表内试听要播 PCM(WAV)

#define MV_PANEL_W 320.0
#define MV_PANEL_H 410.0   // ★ 2.8.8：400 → 410（让 voiceTable 多露一行；标题/行高都缩了）
#define MV_FAB_SIZE 38.0

// ★ 2.8.7：带「试听」按钮的音色单元。
//   以前列表里只有"长按删除"，想知道一个音色好不好听只能回面板发一条 —— 这里直接就地试听。
@interface MVVoiceCell : UITableViewCell
@property (nonatomic, strong) UIView *accBox;
@property (nonatomic, strong) UILabel *tickLabel;
@property (nonatomic, strong) UIButton *playBtn;
@property (nonatomic, copy) void (^onPlay)(void);
@end

@implementation MVVoiceCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.accBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 86, 30)];
        self.tickLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, 5, 18, 20)];
        self.tickLabel.text = @"✓";
        self.tickLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        self.tickLabel.textColor = [UIColor colorWithWhite:0 alpha:0.55];
        [self.accBox addSubview:self.tickLabel];
        self.playBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        self.playBtn.frame = CGRectMake(22, 4, 60, 24);
        self.playBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [self.playBtn setTitle:@"试听" forState:UIControlStateNormal];
        [self.playBtn setTitleColor:[UIColor colorWithRed:0 green:0.42 blue:0.95 alpha:1]
                           forState:UIControlStateNormal];
        self.playBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.05];
        self.playBtn.layer.cornerRadius = 12;
        self.playBtn.layer.borderWidth = 0.5;
        self.playBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;
        [self.playBtn addTarget:self action:@selector(mvPlayTap) forControlEvents:UIControlEventTouchUpInside];
        [self.accBox addSubview:self.playBtn];
        self.accessoryView = self.accBox;
    }
    return self;
}
- (void)mvPlayTap { if (self.onPlay) self.onPlay(); }
@end

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
// ★ 2.8.7
@property (nonatomic, strong) AVAudioPlayer *auditionPlayer;
@property (nonatomic, strong) UIButton *presetBtn;
@property (nonatomic, strong) UIButton *moreBtn;
@property (nonatomic, strong) UIButton *templateBtn;
@property (nonatomic, strong) UISegmentedControl *qwenModelSeg;
@property (nonatomic, strong) NSArray *voiceRows;      // 扁平行（含分节标题行）
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
    pan.cancelsTouchesInView = NO; pan.delaysTouchesBegan = NO;   // ★ 2.8.12 修键盘偶尔不弹
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

    // ★ 2.8.7：⋯ 更多（文本模板 / 音色预设 / 清缓存 / 复制日志路径）
    self.moreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.moreBtn.frame = CGRectMake(W - 72, 6, 28, 28);
    [self.moreBtn setTitle:@"⋯" forState:UIControlStateNormal];
    self.moreBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [self.moreBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
    [self.moreBtn addTarget:self action:@selector(onMoreTap) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.moreBtn];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 120, 20)];
    title.text = @"我的语音";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithWhite:0 alpha:0.9];
    [self.homeView addSubview:title];

    // 文字输入（★ 2.8.10：84 → 124，吸收主界面底部富余空间，长文本更少滚动）
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(14, 36, W - 28, 124)];
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
    // ★ 2.8.7：纠偏 + 模板 并排（原来纠偏独占一行）
    self.polishBtn.frame = CGRectMake(14, 168, (W - 38) * 0.60, 30);
    [self.polishBtn setTitle:@"✨ 一键纠偏" forState:UIControlStateNormal];
    self.polishBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    [self.polishBtn setTitleColor:[UIColor colorWithRed:0 green:0.42 blue:0.95 alpha:1]
                         forState:UIControlStateNormal];
    self.polishBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.polishBtn.layer.cornerRadius = 12;
    self.polishBtn.layer.borderWidth = 0.5;
    self.polishBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    [self.polishBtn addTarget:self action:@selector(onPolish) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.polishBtn];

    // ★ 2.8.7：常用文本模板（一键把整段文字换成模板内容）
    self.templateBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.templateBtn.frame = CGRectMake(14 + (W - 38) * 0.60 + 10, 168, (W - 38) * 0.40 - 10, 30);
    [self.templateBtn setTitle:@"模板" forState:UIControlStateNormal];
    self.templateBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    [self.templateBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.75] forState:UIControlStateNormal];
    self.templateBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
    self.templateBtn.layer.cornerRadius = 12;
    self.templateBtn.layer.borderWidth = 0.5;
    self.templateBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    [self.templateBtn addTarget:self action:@selector(onTemplateTap) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.templateBtn];

    // 音色选择（一行）
    self.voiceSelectBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.voiceSelectBtn.frame = CGRectMake(14, 206, W - 28, 40);
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
    self.sendBtn.frame = CGRectMake(14, 254, (W - 38) * 0.58, 42);
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
    self.previewBtn.frame = CGRectMake(14 + (W - 38) * 0.58 + 10, 254, (W - 38) * 0.42 - 10, 42);
    // ★ 2.8.7：这个按钮走的是系统 AVSpeech【本机】朗读，不是云端音色 —— 名字说清楚
    [self.previewBtn setTitle:@"本机试听" forState:UIControlStateNormal];
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
    self.cloneBtn.frame = CGRectMake(14, 304, W - 28, 40);
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
    self.sessionLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, MV_PANEL_H - 50, W - 32, 18)];   // ★ 2.8.10：382 → 360，贴住内容区不再悬空
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
        // ★ 2.8.7：改成显示"当前用的是什么模型、能不能调"——
        //   千问不能调的唯一原因就是模型是标准版，这里直接写出来省得用户猜。
        (void)nQwen; (void)nMine;
        if (MVTTSProvider() == 0) {
            NSString *m = MVModelForVoice(MVGetStr(@"currentVoiceID"));
            NSArray *dl = MVDialectListForModel(m);
            NSString *dg = MVGetStr(@"cosyDialect");
            self.sectionLabel.text = [NSString stringWithFormat:@"%@%@%@",
                m.length ? m : @"未选音色（去「＋音色管理」）",
                dg.length ? [NSString stringWithFormat:@" · %@", dg] : @"",
                dl.count ? [NSString stringWithFormat:@" · 可 %lu 种方言", (unsigned long)dl.count] : @""];
        } else {
            NSString *qm = MVQwenModel();
            self.sectionLabel.text = [NSString stringWithFormat:@"%@ · %@",
                qm, MVQwenSupportsInstructions(qm) ? @"风格/语速可调" : @"不可调（点风格会自动换可调版）"];
        }
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
    [self updateQwenSeg];                           // ★ 2.8.7
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

    // ★ 2.8.7：最近使用置顶（最多 5 个，且仍在当前搜索/过滤结果里）
    NSMutableArray *rec = [NSMutableArray array];
    for (NSString *vid in MVRecentVoices()) {
        for (NSDictionary *d in self.filteredVoices) {
            if ([d[@"voiceID"] isEqualToString:vid]) { [rec addObject:d]; break; }
        }
        if (rec.count >= 5) break;
    }
    if (rec.count) [secs insertObject:@{@"title": [NSString stringWithFormat:@"最近使用 · %lu", (unsigned long)rec.count],
                                        @"items": rec} atIndex:0];

    self.voiceSections = secs;

    // ★ 2.8.7：拍平成「单节 + 行内标题行」。
    //   原因：UITableViewStylePlain 的 section header 是【悬浮】的（滚动时压在列表上），
    //   而且 iOS 15+ 还会给每节插 sectionHeaderTopPadding —— 表现就是用户说的
    //   「千问预置 · 29 怎么固定住了 / 不往下滑看不见」。改成普通标题行后跟着列表一起滚。
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *s in secs) {
        [rows addObject:@{@"__title": s[@"title"]}];
        [rows addObjectsFromArray:s[@"items"]];
    }
    self.voiceRows = rows;
}

// ★ 2.8.7：单节扁平行；标题行返回 nil（调用方据此画标题/跳过点击）
- (NSDictionary*)voiceAt:(NSIndexPath*)ip {
    if (ip.row < 0 || ip.row >= (NSInteger)self.voiceRows.count) return nil;
    NSDictionary *r = self.voiceRows[(NSUInteger)ip.row];
    return r[@"__title"] ? nil : r;
}
- (NSDictionary*)voiceRowAt:(NSIndexPath*)ip {
    if (ip.row < 0 || ip.row >= (NSInteger)self.voiceRows.count) return nil;
    return self.voiceRows[(NSUInteger)ip.row];
}

- (void)updateDialectButtons {
    BOOL cosy = (MVTTSProvider() == 0);
    if (self.dialectBtn) {
        NSString *bv = MVGetStr(@"mvBuiltinVoice");
        if (bv.length) {
            [self.dialectBtn setTitle:@"音色：阳江话(内置)" forState:UIControlStateNormal];
        } else {
            NSString *d = MVGetStr(@"cosyDialect");
            [self.dialectBtn setTitle:(d.length ? [NSString stringWithFormat:@"方言：%@", d] : @"无方言")
                             forState:UIControlStateNormal];
        }
    }
    // ★ 2.8.7：千问的自定义指令写的是 qwenInstruction（对应官方 instructions 字段），
    //   克隆写的是 cosyInstruction（官方 instruction）。两者别混。
    NSString *inst = cosy ? MVGetStr(@"cosyInstruction") : MVQwenCustomInstruction();
    [self.instrBtn setTitle:(inst.length ? @"指令：已自定义" : @"自定义指令")
                   forState:UIControlStateNormal];
    [self.instrBtn setTitleColor:(inst.length ? [UIColor colorWithRed:0 green:0.42 blue:0.95 alpha:1]
                                              : [UIColor colorWithWhite:0 alpha:0.8])
                        forState:UIControlStateNormal];
    if (self.presetBtn) {
        NSUInteger n = MVVoicePresets().count;
        [self.presetBtn setTitle:(n ? [NSString stringWithFormat:@"预设 %lu", (unsigned long)n] : @"预设")
                        forState:UIControlStateNormal];
    }
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
    // ★ 2.8.27：顶部加「无」——用当前音色（克隆）原声，不加任何方言指令。
    //   选了克隆音色但只想用克隆声、不想带方言时，点这个即可，不必再选一个方言。
    NSString *noneTitle = (cur.length == 0) ? @"✓ 无（用当前音色原声）" : @"无（用当前音色原声）";
    [ac addAction:[UIAlertAction actionWithTitle:noneTitle style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){
            MVSetShared(@"cosyDialect", @"");
            MVSetShared(@"mvBuiltinVoice", @"");
            [self updateDialectButtons];
            [MyVoiceCloud clearSynthesisCache];
            [self prewarmNow];
            [[MyVoiceManager shared] toast:@"已设为：无方言（用当前音色原声）"];
        }]];
    for (NSString *d in ds) {
        NSString *title = [d isEqualToString:cur] ? [@"✓ " stringByAppendingString:d] : d;
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                // ★ 2.8.6：方言是独立维度，只写 cosyDialect ——
                //   语气（自定义指令 / 一键风格）由 MVCosyInstruction 自动拼在后半句，
                //   所以这里绝不能去覆盖 cosyInstruction（旧写法会把用户写的语气顶掉）。
                MVSetShared(@"cosyDialect", d);
                MVSetShared(@"mvBuiltinVoice", @"");
                [self updateDialectButtons];
                [MyVoiceCloud clearSynthesisCache];   // 换了指令必须清缓存，否则命中旧音频
                [self prewarmNow];
                [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已设为%@", d]];
            }]];
    }
    // ★ 2.8.29：内置音色（用内置样本克隆，真·阳江话）
    [ac addAction:[UIAlertAction actionWithTitle:@"阳江话（内置样本克隆）" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){
            MVSetShared(@"cosyDialect", @"");
            MVSetShared(@"mvBuiltinVoice", @"yangjiang");
            [[MyVoiceManager shared] toast:@"正在生成阳江话音色（首次需联网克隆，约 10~30 秒）…"];
            [MyVoiceBuiltin ensureYangjiangCompletion:^(NSString *vid, NSError *e){
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!vid) {
                        MVSetShared(@"mvBuiltinVoice", @"");
                        [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"阳江话生成失败：%@", e.localizedDescription ?: @"未知错误"]];
                        return;
                    }
                    MVSetShared(@"currentVoiceID", vid);
                    MVSetShared(@"ttsProvider", @0);
                    MVSetShared(@"cosyModel", MVCosyModel());
                    [MyVoiceCloud clearSynthesisCache];
                    [self updateDialectButtons];
                    [self prewarmNow];
                    [[MyVoiceManager shared] toast:@"阳江话音色已就绪（内置样本克隆，真·阳江话）"];
                });
            }];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.dialectBtn;
    ac.popoverPresentationController.sourceRect = self.dialectBtn.bounds;
    UIViewController *top = [MyVoiceResolver anyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}

// 自定义指令：改的是语气/情绪/语速/角色，不是口音（口音请用左边的方言）
- (void)onInstructionTap {
    BOOL cosy = (MVTTSProvider() == 0);
    NSString *cur = cosy ? MVGetStr(@"cosyInstruction") : MVQwenCustomInstruction();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自定义指令"
        message:(cosy
            ? @"用一句自然语言描述「怎么念」，最多 100 字符（汉字算 2）。\n"
               "例：用慵懒随意的语气说，语速慢一点，句尾别拖长。\n"
               "注意：这改的是语气/情绪/语速，改不了口音 —— 方言请用左边的「方言」。"
            : @"千问的自定义指令（官方 instructions 字段）。\n"
               "例：用日常聊天的语气说，语速中等偏慢，不要播音腔。\n"
               "注意：只有「可调版」模型(qwen3-tts-instruct-flash)认这个字段；\n"
               "标准版会忽略它 —— 保存时会自动帮你切到可调版。")
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.text = cur;
        tf.placeholder = @"语气 / 情绪 / 语速 / 角色";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a){
            MVSetShared(@"cosyInstruction", @"");
            MVSetShared(@"qwenInstruction", @"");
            MVSetShared(@"cosyDialect", @"");
            [self updateStyleButtons];
            [self updateDialectButtons];
            [MyVoiceCloud clearSynthesisCache];
            [self prewarmNow];
            [[MyVoiceManager shared] toast:@"已清空指令"];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){
            NSString *t = [ac.textFields.firstObject.text
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (cosy) {
                MVSetShared(@"cosyInstruction", t ?: @"");
                // ★ 2.8.6：自定义指令属于"语气"维度 —— 取代一键风格（互斥），
                //   但**不动 cosyDialect**：方言和语气是两码事，可同时生效（拼成一句）。
                MVSetShared(@"cosyStyle", @0);
            } else {
                // ★ 2.8.7：千问走 instructions，只有可调版模型认 → 顺手切过去
                if (t.length && !MVQwenSupportsInstructions(MVQwenModel())) {
                    MVSetShared(@"qwenModel", @"qwen3-tts-instruct-flash");
                    [self updateQwenSeg];
                }
                MVSetShared(@"qwenInstruction", t ?: @"");
                MVSetShared(@"qwenStyle", @0);
            }
            [self updateStyleButtons];
            [self updateDialectButtons];
            [MyVoiceCloud clearSynthesisCache];
            [self prewarmNow];
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
    self.dialectBtn.titleLabel.adjustsFontSizeToFitWidth = YES;   // ★ 2.8.7：三按钮并排，字要缩
    self.dialectBtn.titleLabel.minimumScaleFactor = 0.7;
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
    self.instrBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.instrBtn.titleLabel.minimumScaleFactor = 0.7;
    [self.instrBtn addTarget:self action:@selector(onInstructionTap) forControlEvents:UIControlEventTouchUpInside];
    [self.pickerView addSubview:self.instrBtn];

    // ★ 2.8.7：预设（音色 + 风格 + 方言 整套切换）
    self.presetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.presetBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    self.presetBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.presetBtn.titleLabel.minimumScaleFactor = 0.7;
    [self.presetBtn setTitle:@"预设" forState:UIControlStateNormal];
    [self.presetBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.8] forState:UIControlStateNormal];
    self.presetBtn.layer.cornerRadius = 12;
    self.presetBtn.layer.borderWidth = 0.5;
    self.presetBtn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.15].CGColor;
    self.presetBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.05];
    [self.presetBtn addTarget:self action:@selector(onPresetTap) forControlEvents:UIControlEventTouchUpInside];
    [self.pickerView addSubview:self.presetBtn];

    // ★ 2.8.7：千问模型档位 —— 千问"调不了"的唯一原因就是模型是标准版。
    //   标准版(qwen3-tts-flash)不支持任何表现参数；可调版(instruct)认 instructions。
    self.qwenModelSeg = [[UISegmentedControl alloc] initWithItems:
        @[@"标准版", @"可调版"]];   // 索引 = MVQwenModelChoices 顺序
    self.qwenModelSeg.frame = CGRectMake(52, 0, W - 66, 24);
    self.qwenModelSeg.selectedSegmentIndex =
        MVQwenSupportsInstructions(MVQwenModel()) ? 1 : 0;
    [self.qwenModelSeg addTarget:self action:@selector(onQwenModelChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerView addSubview:self.qwenModelSeg];

    self.sectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, W - 28, 14)];
    NSUInteger nQwen = 0, nMine = 0;
    for (NSDictionary *d in self.allVoices)
        ([d[@"provider"] integerValue] == 1) ? nQwen++ : nMine++;
    self.sectionLabel.text = [NSString stringWithFormat:
        @"千问 %lu 个 · 我的 %lu 个", (unsigned long)nQwen, (unsigned long)nMine];
    self.sectionLabel.font = [UIFont boldSystemFontOfSize:11];
    self.sectionLabel.textColor = [UIColor colorWithWhite:0 alpha:0.6];
    self.sectionLabel.adjustsFontSizeToFitWidth = YES;   // ★ 2.8.7：状态行现在写模型名，别被截断
    self.sectionLabel.minimumScaleFactor = 0.8;
    [self.pickerView addSubview:self.sectionLabel];
    y += 16;

    self.voiceTable = [[UITableView alloc] initWithFrame:CGRectMake(12, y, W - 24, H - y - 8) style:UITableViewStylePlain];
    self.voiceTable.backgroundColor = [UIColor clearColor];
    self.voiceTable.dataSource = self;
    self.voiceTable.delegate = self;
    self.voiceTable.rowHeight = 30;   // ★ 2.8.8：34 → 30（与 heightForRowAtIndexPath 保持一致）
    self.voiceTable.layer.cornerRadius = 12;
    // ★ 2.8.8：标题行与 cell 之间用细横线隔，单元行用全宽横线
    self.voiceTable.separatorInset = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.pickerView addSubview:self.voiceTable];

    UILongPressGestureRecognizer *lpDel = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onVoiceLongPress:)];
    lpDel.minimumPressDuration = 0.6;
    [self.voiceTable addGestureRecognizer:lpDel];

    [self updateStyleButtons];      // ★ 2.8.5
    [self layoutPickerRows];        // ★ 2.8.5：按当前 provider 摆位（音高行仅克隆可见）
}

// ★ 2.8.7：两个 provider 都显示「风格」胶囊条（千问终于可调了）。
//   千问的调节只能走 instructions，且仅 qwen3-tts-instruct-flash 认 —— 所以多了「千问模型」一档。
- (void)layoutPickerRows {
    CGFloat W = MV_PANEL_W, H = MV_PANEL_H;
    BOOL cosy = (MVTTSProvider() == 0);

    self.toneLabel.text = @"风格";
    self.emotionSeg.hidden = YES;        // 旧的「语气」段控已并入风格条（它的值以前压根发不出去）
    self.styleScroll.hidden = NO;

    // 克隆音色的模型不支持 instruction（cosyvoice-v2/v1）→ 置灰提示；
    // 千问一律可点（不支持时 onStyleTap 会自动切到可调版模型）。
    BOOL styleOK = cosy ? MVCosySupportsInstruction(MVModelForVoice(MVGetStr(@"currentVoiceID"))) : YES;
    self.styleScroll.alpha = styleOK ? 1.0 : 0.35;
    self.styleScroll.userInteractionEnabled = styleOK;

    CGFloat y = 84;
    // ★ 关键修复：标签占 14..50，胶囊必须从 x=52 开始。
    //   旧版把 styleScroll 放在 x=12，于是「风格」两个字和第一个胶囊「默认」【重叠】。
    self.toneLabel.frame   = CGRectMake(14, y + 3, 36, 18);
    self.styleScroll.frame = CGRectMake(52, y, W - 64, 26);
    self.emotionSeg.frame  = CGRectMake(52, y, W - 66, 22);
    y += 28;

    // 第三行：克隆 = 音高；千问 = 模型档位（标准版 / 可调版）
    self.pitchLabel.hidden      = !cosy;
    self.pitchSlider.hidden     = !cosy;
    self.pitchValueLabel.hidden = !cosy;
    self.qwenModelSeg.hidden    = cosy;
    if (cosy) {
        self.pitchLabel.frame      = CGRectMake(14, y, 36, 18);
        self.pitchSlider.frame     = CGRectMake(52, y, W - 126, 18);
        self.pitchValueLabel.frame = CGRectMake(W - 66, y, 52, 18);
        y += 24;
    } else {
        self.qwenModelSeg.frame = CGRectMake(52, y, W - 66, 24);
        y += 26;
    }

    // 第四行按钮：克隆 = [方言][指令][预设]；千问 = [指令][预设]
    CGFloat gap = 6;
    self.dialectBtn.hidden = !cosy;
    self.instrBtn.hidden   = NO;
    self.presetBtn.hidden  = NO;
    if (cosy) {
        CGFloat bw = (W - 24 - gap * 2) / 3;
        self.dialectBtn.frame = CGRectMake(12, y, bw, 26);
        self.instrBtn.frame   = CGRectMake(12 + bw + gap, y, bw, 26);
        self.presetBtn.frame  = CGRectMake(12 + (bw + gap) * 2, y, bw, 26);
    } else {
        CGFloat bw = (W - 24 - gap) / 2;
        self.instrBtn.frame  = CGRectMake(12, y, bw, 26);
        self.presetBtn.frame = CGRectMake(12 + bw + gap, y, bw, 26);
    }
    y += 30;
    [self updateDialectButtons];

    self.sectionLabel.frame = CGRectMake(14, y, W - 28, 14);
    y += 14;     // ★ 2.8.8：16 → 14（让 sectionLabel 紧贴 voiceTable）
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
// ★ 2.8.7：千问那边语速是写进 instructions 的，改完必须清缓存 ——
//   否则 key 没变、直接命中旧音频，还是"调了没反应"。
- (void)onSpeedChanged:(UISlider*)s {
    [self updateSpeedLabel];
    if (MVTTSProvider() == 1) {
        MVSetShared(@"qwenSpeed", @(s.value));
        [MyVoiceCloud clearSynthesisCache];
        [self prewarmNow];
    } else {
        MVSetShared(@"cosyRate", @(s.value));
    }
}
- (void)onEmotionChanged:(UISegmentedControl*)seg { MVSetShared(@"qwenEmotion", [self emotionValueForIndex:seg.selectedSegmentIndex]); }

// ★ 2.8.5：一键风格 —— 落到 CosyVoice 的 instruction（这是"去 AI 味"最有效的旋钮）
- (void)onStyleTap:(UIButton*)b {
    NSInteger idx = b.tag - 2000;

    // ★ 2.8.7：千问分支也终于可调了。
    //   千问没有 rate/pitch/volume 这类数值参数，调节只能走 instructions，
    //   且只有 qwen3-tts-instruct-flash（可调版）认这个字段。
    //   所以点风格时若还是标准版，直接【就地换成可调版】——「一键」就该一步到位，
    //   而不是让用户去猜"为什么点了没反应"。
    if (MVTTSProvider() == 1) {
        BOOL needSwitch = !MVQwenSupportsInstructions(MVQwenModel());
        if (needSwitch) {
            MVSetShared(@"qwenModel", @"qwen3-tts-instruct-flash");
            [self updateQwenSeg];
        }
        MVSetShared(@"qwenStyle", @(idx));
        MVSetShared(@"qwenInstruction", @"");         // 选预设 = 清掉自定义指令（同一维度）
        double rec = MVStyleRate(idx);
        if (rec > 0.01) {
            MVSetShared(@"qwenSpeed", @(rec));
            self.speedSlider.value = (float)rec;
            [self updateSpeedLabel];
        }
        [self updateStyleButtons];
        [MyVoiceCloud clearSynthesisCache];
        [self prewarmNow];
        NSArray *names = MVStyleNames();
        NSString *nm = (idx >= 0 && idx < (NSInteger)names.count) ? names[(NSUInteger)idx] : @"默认";
        [[MyVoiceManager shared] toast:needSwitch
            ? [NSString stringWithFormat:@"风格：%@（已切到可调版模型，标准版不支持调节）", nm]
            : [NSString stringWithFormat:@"风格：%@（千问）", nm]];
        return;
    }

    MVSetShared(@"cosyStyle", @(idx));
    // 选预设清掉自定义指令（同属"语气"维度，互斥）；注意别碰 cosyDialect —— 方言独立
    MVSetShared(@"cosyInstruction", @"");
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
    NSInteger cur = (MVTTSProvider() == 1) ? MVQwenStyle() : MVCosyStyle();   // ★ 2.8.7
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
// ★ 2.8.7：只用一节（标题做成了行内行，见 rebuildVoiceSections）；
//   不再实现 titleForHeaderInSection —— 那是列表被"固定表头挡住"的根源。
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.voiceRows.count;
}
// ★ 2.8.8：标题行压扁 + cell 行高缩 30，让 picker 排版更紧凑。
//   用户反馈：分节标题行与音色单元行之间空白过大。
- (CGFloat)tableView:(UITableView*)tableView heightForRowAtIndexPath:(NSIndexPath*)ip {
    NSDictionary *r = [self voiceRowAt:ip];
    return r[@"__title"] ? 20.0 : 30.0;             // 标题行 20，cell 30（原 24/34 → 缩 ~12%）
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary *row = [self voiceRowAt:indexPath];
    // 分节标题行
    if (![self voiceAt:indexPath]) {
        static NSString *tid = @"mvSectionRow";
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:tid];
        if (!c) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:tid];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.backgroundColor = [UIColor clearColor];
            // ★ 2.8.8：标题行字号、颜色都加重，视觉上"压"在下面 cell 上；
            //   原 24 → 20（高度），原 0.42 透明度 → 0.55，更明显的"开始一节"感。
            c.textLabel.font = [UIFont boldSystemFontOfSize:11];
            c.textLabel.textColor = [UIColor colorWithWhite:0 alpha:0.55];
        }
        c.textLabel.text = row[@"__title"];
        return c;
    }
    static NSString *cid = @"mvVoiceCell";
    MVVoiceCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[MVVoiceCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.textLabel.textColor = [UIColor colorWithWhite:0 alpha:0.85];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0 alpha:0.25];
    }
    NSDictionary *d = [self voiceAt:indexPath];
    cell.textLabel.text = d[@"name"] ?: d[@"voiceID"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
        ([d[@"provider"] integerValue] == 1) ? @"千问" : @"克隆", d[@"model"] ?: @""];
    cell.tickLabel.hidden = ![d[@"voiceID"] isEqualToString:self.selectedVoiceID];
    cell.onPlay = ^{ [self auditionVoice:d]; };
    return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = [self voiceAt:indexPath];
    if (!d) return;                                  // 标题行不响应点击
    self.selectedVoiceID = d[@"voiceID"];
    MVMarkVoiceUsed(d[@"voiceID"] ?: @"");           // ★ 2.8.7：记最近使用
    if ([d[@"provider"] integerValue] == 1) {
        MVSetShared(@"ttsProvider", @1);
        MVSetShared(@"qwenVoice", self.selectedVoiceID);
        MVSetShared(@"qwenModel", d[@"model"] ?: @"qwen3-tts-flash");
        MVSetShared(@"mvBuiltinVoice", @"");
    } else {
        MVSetShared(@"ttsProvider", @0);
        MVSetShared(@"currentVoiceID", self.selectedVoiceID);
        MVSetShared(@"mvBuiltinVoice", [self.selectedVoiceID isEqualToString:[MyVoiceBuiltin yangjiangVoiceID]] ? @"yangjiang" : @"");
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
    if (!d) return;                                   // ★ 2.8.7：标题行跳过
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
        MVSetSharedVoiceList(keep);   // ★ 2.8.13 跨 App 共享（微信/QQ 互通）
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

#pragma mark - ★ 2.8.7 列表内试听 / 预设 / 模板 / 缓存管理 / 最近使用

// 就地试听：走【真实云端合成】，听到的就是发出去的那个声音（还会带上当前风格/方言/语速）。
// 以前面板上的「预览」用的是系统 AVSpeech 本地音色，跟云端音色根本不是一回事 ——
// 想判断"这个音色/风格到底好不好听"必须听云端这一份。
- (void)auditionVoice:(NSDictionary*)d {
    NSString *vid = d[@"voiceID"] ?: @"";
    if (!vid.length) return;
    if (MVEngineMode() != 1) { [[MyVoiceManager shared] toast:@"离线模式下无法云端试听"]; return; }
    if (!MVAPIKey().length)  { [[MyVoiceManager shared] toast:@"未配置 API Key（设置→我的语音）"]; return; }

    NSInteger want = [d[@"provider"] integerValue];       // 1=千问 0=克隆
    // 合成接口是按「当前服务商」分流的，试听别的音色时必须临时切过去（结束后恢复）
    NSInteger oldProv = MVTTSProvider();
    NSString *oldClone = MVGetStr(@"currentVoiceID");
    NSString *oldQwen  = MVGetStr(@"qwenVoice");
    if (want != oldProv) MVSetShared(@"ttsProvider", @(want));
    if (want == 0) MVSetShared(@"currentVoiceID", vid);
    else           MVSetShared(@"qwenVoice", vid);

    NSString *text = @"你好，我是这个声音，你听听自然不自然。";
    [[MyVoiceManager shared] toast:@"正在合成试听…"];
    __weak typeof(self) ws = self;
    [[MyVoiceCloud shared] synthesizeText:text voiceID:vid completion:^(NSData *pcm, NSError *err){
        MVSetShared(@"ttsProvider", @(oldProv));
        if (oldClone.length) MVSetShared(@"currentVoiceID", oldClone);
        if (oldQwen.length)  MVSetShared(@"qwenVoice", oldQwen);
        if (!pcm.length) {
            NSString *m = err.localizedDescription ?: @"试听合成失败";
            MVLog(@"[audition] %@", m);
            [[MyVoiceManager shared] toast:m];
            return;
        }
        [ws playPCM:pcm];
    }];
}

// 云端回的是 16k / 单声道 / S16 PCM，播放必须先补 WAV 头
- (void)playPCM:(NSData*)pcm {
    NSData *wav = MVWavFromPCM(pcm, 16000, 1, 16);
    if (!wav.length) { [[MyVoiceManager shared] toast:@"试听音频无效"]; return; }
    NSError *e = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    self.auditionPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&e];
    if (e || !self.auditionPlayer) {
        MVLog(@"[audition] 播放失败 %@", e);
        [[MyVoiceManager shared] toast:@"试听播放失败"];
        return;
    }
    [self.auditionPlayer play];
}

- (void)updateQwenSeg {
    if (!self.qwenModelSeg) return;
    NSArray *c = MVQwenModelChoices();
    NSString *cur = MVQwenModel();
    NSInteger idx = [c indexOfObject:cur];
    self.qwenModelSeg.selectedSegmentIndex = (idx == NSNotFound) ? 0 : idx;
}

- (void)onQwenModelChanged:(UISegmentedControl*)seg {
    NSArray *c = MVQwenModelChoices();
    NSInteger i = seg.selectedSegmentIndex;
    if (i < 0 || i >= (NSInteger)c.count) return;
    MVSetShared(@"qwenModel", c[(NSUInteger)i]);
    [MyVoiceCloud clearSynthesisCache];
    [self refreshVoiceState];
    [[MyVoiceManager shared] toast:MVQwenSupportsInstructions(c[(NSUInteger)i])
        ? @"已切到可调版：风格 / 语速 / 自定义指令都生效"
        : @"已切到标准版：不支持风格 / 语速调节（音色最全）"];
}

// ===== 预设：音色 + 风格 + 方言 整套 =====
- (void)onPresetTap {
    NSArray *ps = MVVoicePresets();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"预设（音色+风格+方言）"
        message:@"点一个套用整套配置；也可以把当前配置存成预设。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < ps.count; i++) {
        NSDictionary *pf = ps[i];
        NSString *sub = [pf[@"provider"] integerValue] == 1
            ? [NSString stringWithFormat:@"千问 %@ · %@", pf[@"qwenVoice"] ?: @"", MVQwenModelLabel(pf[@"qwenModel"] ?: @"")]
            : [NSString stringWithFormat:@"克隆 %@%@", pf[@"voiceID"] ?: @"",
               [pf[@"dialect"] length] ? [NSString stringWithFormat:@" · %@", pf[@"dialect"]] : @""];
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@（%@）", pf[@"name"] ?: @"预设", sub]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                MVApplyVoicePreset(pf);
                [MyVoiceCloud clearSynthesisCache];
                [self refreshVoiceState];
                [self.voiceTable reloadData];
                [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已套用「%@」", pf[@"name"] ?: @"预设"]];
            }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"＋ 把当前配置存为预设" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [self savePresetDialog]; }]];
    if (ps.count) {
        [ac addAction:[UIAlertAction actionWithTitle:@"删除预设…" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *a){ [self deletePresetDialog]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.presetBtn ?: self.pickerView;
    ac.popoverPresentationController.sourceRect = self.presetBtn.bounds;
    [self mvPresent:ac];
}

- (void)savePresetDialog {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"存为预设"
        message:@"会把当前的音色 + 风格 + 方言/指令 + 语速/音高 一起存下来。"
        preferredStyle:UIAlertControllerStyleAlert];
    NSString *defName = (MVTTSProvider() == 1) ? MVQwenVoice() : @"我的克隆";
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.text = defName; tf.placeholder = @"预设名字"; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *nm = [ac.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!nm.length) nm = @"未命名";
        NSMutableArray *arr = [NSMutableArray arrayWithArray:MVVoicePresets()];
        NSDictionary *pf = MVCaptureVoicePreset(nm);
        // 同名覆盖，不堆叠
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            if ([arr[(NSUInteger)i][@"name"] isEqualToString:nm]) [arr removeObjectAtIndex:(NSUInteger)i];
        }
        [arr addObject:pf];
        MVSaveVoicePresets(arr);
        [self updateDialectButtons];
        [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已存预设「%@」", nm]];
    }]];
    [self mvPresent:ac];
}

- (void)deletePresetDialog {
    NSArray *ps = MVVoicePresets();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除预设"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < ps.count; i++) {
        NSString *nm = ps[i][@"name"] ?: @"预设";
        [ac addAction:[UIAlertAction actionWithTitle:nm style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
            NSMutableArray *arr = [NSMutableArray arrayWithArray:MVVoicePresets()];
            for (NSInteger k = (NSInteger)arr.count - 1; k >= 0; k--) {
                if ([arr[(NSUInteger)k][@"name"] isEqualToString:nm]) [arr removeObjectAtIndex:(NSUInteger)k];
            }
            MVSaveVoicePresets(arr);
            [self updateDialectButtons];
            [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已删除「%@」", nm]];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self mvPresent:ac];
}

// ===== 常用文本模板 =====
- (void)onTemplateTap {
    NSArray *ts = MVTextTemplates();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"常用文本"
        message:@"点一条就把输入框换成它的内容。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *t in ts) {
        NSString *title = t[@"title"] ?: t[@"text"];
        NSString *body  = t[@"text"] ?: @"";
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            self.textView.text = body;                 // 触发 TextDidChange → 自动预合成
            [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已填入「%@」", title]];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"＋ 把当前文字存为模板" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [self saveTemplateDialog]; }]];
    if (ts.count) {
        [ac addAction:[UIAlertAction actionWithTitle:@"删除模板…" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *a){ [self deleteTemplateDialog]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.templateBtn ?: self.homeView;
    ac.popoverPresentationController.sourceRect = self.templateBtn.bounds;
    [self mvPresent:ac];
}

- (void)saveTemplateDialog {
    NSString *cur = [self.textView.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"存为模板"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.text = cur.length > 8 ? [cur substringToIndex:8] : (cur.length ? cur : @"模板");
        tf.placeholder = @"模板名字";
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.text = cur;
        tf.placeholder = @"模板内容";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *nm = [ac.textFields[0].text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *tx = [ac.textFields[1].text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!nm.length) nm = @"模板";
        if (!tx.length) { [[MyVoiceManager shared] toast:@"内容为空"]; return; }
        NSMutableArray *arr = [NSMutableArray arrayWithArray:MVTextTemplates()];
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            if ([arr[(NSUInteger)i][@"title"] isEqualToString:nm]) [arr removeObjectAtIndex:(NSUInteger)i];
        }
        [arr addObject:@{ @"title": nm, @"text": tx }];
        MVSaveTextTemplates(arr);
        [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已存模板「%@」", nm]];
    }]];
    [self mvPresent:ac];
}

- (void)deleteTemplateDialog {
    NSArray *ts = MVTextTemplates();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除模板"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *t in ts) {
        NSString *nm = t[@"title"] ?: @"模板";
        [ac addAction:[UIAlertAction actionWithTitle:nm style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
            NSMutableArray *arr = [NSMutableArray arrayWithArray:MVTextTemplates()];
            for (NSInteger k = (NSInteger)arr.count - 1; k >= 0; k--) {
                if ([arr[(NSUInteger)k][@"title"] isEqualToString:nm]) [arr removeObjectAtIndex:(NSUInteger)k];
            }
            MVSaveTextTemplates(arr);
            [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已删除「%@」", nm]];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self mvPresent:ac];
}

// ===== ⋯ 更多：模板 / 预设 / 缓存管理 / 日志路径 =====
- (void)onMoreTap {
    NSDictionary *st = [MyVoiceCloud cacheStats];
    NSUInteger cnt = [st[@"count"] unsignedIntegerValue];
    double mb = [st[@"bytes"] doubleValue] / 1048576.0;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更多"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"常用文本模板" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [self onTemplateTap]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"音色预设（音色+风格+方言）" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [self onPresetTap]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"清除合成缓存（%lu 条 / %.1f MB）",
            (unsigned long)cnt, mb]
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
            [MyVoiceCloud clearSynthesisCache];
            [[MyVoiceManager shared] toast:[NSString stringWithFormat:@"已清除 %lu 条缓存", (unsigned long)cnt]];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制日志路径（排查用）" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){
            UIPasteboard.generalPasteboard.string = MVLogFilePath() ?: @"";
            [[MyVoiceManager shared] toast:@"日志路径已复制到剪贴板"];
        }]];
    // ★ 2.8.34：自建服务器的开关/地址统一到「系统设置 → 我的语音 → 自建服务器」里配置。
    //   面板这里【绝不能再写】这三个键 —— 面板跑在微信进程里，MVSetShared 会把值写进微信容器，
    //   而 MVGet 是「容器优先」，会把设置页写在 jbroot 里的值遮住 → 设置页改了不生效。
    [ac addAction:[UIAlertAction actionWithTitle:
        [NSString stringWithFormat:@"自建服务器：%@", MVSelfHostEnabled() ? @"已开启" : @"已关闭"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showSelfHostInfo]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.moreBtn ?: self.homeView;
    ac.popoverPresentationController.sourceRect = self.moreBtn.bounds;
    [self mvPresent:ac];
}

// ★ 2.8.34：只读状态 + 指路（配置统一放在 系统设置 → 我的语音 → 自建服务器）
- (void)showSelfHostInfo {
    BOOL on = MVSelfHostEnabled();
    NSString *msg = [NSString stringWithFormat:
        @"状态：%@\n服务器：%@\n\n开关和地址请在【系统设置 → 我的语音 → 自建服务器】里修改，\n改完直接回聊天页即可生效（不用重启）。\n\n开启后：克隆 / CosyVoice 音色走你自己的电脑（免费、不耗额度）；\n千问预置音色仍走阿里云。\n\n⚠️ 首次开启或换了地址后，请重新点「＋音色管理」复刻一次克隆音色\n（参考音频会保存到手机本机，合成时发给你的服务器）。",
        on ? @"已开启（CosyVoice 族走本地服务器，免额度）" : @"已关闭",
        MVSelfHostURL() ?: @"(未填写)"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自建服务器"
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self mvPresent:ac];
}

// iOS 上从 action sheet 弹出要挂到最顶层 VC（面板是挂在 window 上的，没有自己的 VC）
- (void)mvPresent:(UIAlertController*)ac {
    UIViewController *top = [MyVoiceResolver anyWindow].rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}

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
    p.cancelsTouchesInView = NO; p.delaysTouchesBegan = NO;   // ★ 2.8.12 同上
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
