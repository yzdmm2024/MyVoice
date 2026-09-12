#import "MyVoicePanel.h"
#import "MyVoiceCommon.h"
#import "MyVoiceEngine.h"
#import "MyVoiceManager.h"
#import "MyVoiceResolver.h"
#import "MyVoiceCloneController.h"
#import "MyVoiceCloud.h"
#import <UIKit/UIKit.h>

@interface MyVoicePanel () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *homeView;
@property (nonatomic, strong) UIView *pickerView;

// home
@property (nonatomic, strong) UIView *dragBar;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *voiceSelectBtn;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) UIButton *cloneBtn;
@property (nonatomic, strong) UIButton *previewBtn;
@property (nonatomic, strong) UILabel *sessionLabel;
@property (nonatomic, strong) UIButton *closeBtn;

// picker
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

#define MV_PANEL_W 320.0
#define MV_PANEL_H 420.0

#pragma mark - 初始化/显示

- (NSArray<NSDictionary*>*)voiceList {
    if (MVTTSProvider() == 1) return MVQwenVoiceList();
    return MVVoices();
}

- (void)show {
    if (![NSThread isMainThread]) { MVOnMain(^{ [self show]; }); return; }
    if (self.fab) return;

    // ★ 2.2.7：提前把 DNS + TLS 建好（实测首次合成 0.89s 里约 0.3~0.4s 是握手）
    [[MyVoiceCloud shared] prewarmConnection];
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

#pragma mark - 构建面板

- (void)buildPanel {
    UIWindow *w = [MyVoiceResolver anyWindow];
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(w.bounds.size.width - MV_PANEL_W - 16,
                                                         w.bounds.size.height - MV_PANEL_H - 90,
                                                         MV_PANEL_W, MV_PANEL_H)];
    self.panel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.panel.layer.cornerRadius = 16;
    self.panel.layer.shadowOpacity = 0.25;
    self.panel.layer.shadowRadius = 12;
    self.panel.hidden = YES;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)];
    [self.panel addGestureRecognizer:pan];

    [w addSubview:self.panel];

    [self buildHomeView];
    [self buildPickerView];

    [self.panel addSubview:self.homeView];
    [self.panel addSubview:self.pickerView];

    self.homeView.hidden = NO;
    self.pickerView.hidden = YES;

    [self refreshVoiceState];
    [self refreshSession];
}

#pragma mark - 主视图

- (void)buildHomeView {
    self.homeView = [[UIView alloc] initWithFrame:self.panel.bounds];

    // 拖动条 + 标题
    self.dragBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MV_PANEL_W, 34)];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 7, 180, 20)];
    title.text = @"我的语音";
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textColor = [UIColor labelColor];
    [self.dragBar addSubview:title];
    UILabel *grip = [[UILabel alloc] initWithFrame:CGRectMake(MV_PANEL_W - 44, 6, 32, 20)];
    grip.text = @"≡";
    grip.textAlignment = NSTextAlignmentCenter;
    grip.font = [UIFont systemFontOfSize:16];
    grip.textColor = [UIColor secondaryLabelColor];
    [self.dragBar addSubview:grip];
    UIPanGestureRecognizer *p2 = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)];
    [self.dragBar addGestureRecognizer:p2];
    [self.homeView addSubview:self.dragBar];

    // 文字输入
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(12, 42, MV_PANEL_W - 24, 80)];
    self.textView.layer.cornerRadius = 10;
    self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    self.textView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    [self.homeView addSubview:self.textView];

    // ★ 2.2.7：文字一改就（防抖后）后台预合成，点「发送」时命中缓存 → 合成耗时归零。
    //   用通知而不是 delegate：面板里没人占 textView.delegate，通知零侵入。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTextViewChanged:)
                                                 name:UITextViewTextDidChangeNotification
                                               object:self.textView];

    // 当前音色选择条（仿截图入口）
    self.voiceSelectBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.voiceSelectBtn.frame = CGRectMake(12, 130, MV_PANEL_W - 24, 42);
    self.voiceSelectBtn.backgroundColor = [UIColor systemBackgroundColor];
    self.voiceSelectBtn.layer.cornerRadius = 10;
    self.voiceSelectBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    self.voiceSelectBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.voiceSelectBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.voiceSelectBtn addTarget:self action:@selector(showPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.voiceSelectBtn];

    // 合成 / 音色管理
    self.sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendBtn setTitle:@"① 合成语音" forState:UIControlStateNormal];
    self.sendBtn.backgroundColor = [UIColor systemBlueColor];
    [self.sendBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.sendBtn.frame = CGRectMake(12, 182, 130, 42);
    self.sendBtn.layer.cornerRadius = 10;
    self.sendBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.sendBtn addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.sendBtn];

    self.cloneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cloneBtn setTitle:@"音色管理" forState:UIControlStateNormal];
    self.cloneBtn.frame = CGRectMake(156, 182, MV_PANEL_W - 168, 42);
    self.cloneBtn.layer.cornerRadius = 10;
    self.cloneBtn.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.cloneBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.cloneBtn addTarget:self action:@selector(onClone) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.cloneBtn];

    self.previewBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.previewBtn setTitle:@"预览" forState:UIControlStateNormal];
    self.previewBtn.frame = CGRectMake(12, 232, MV_PANEL_W - 24, 40);
    self.previewBtn.layer.cornerRadius = 10;
    self.previewBtn.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.previewBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.previewBtn addTarget:self action:@selector(onPreview) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.previewBtn];

    // 会话状态
    self.sessionLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 282, MV_PANEL_W - 24, 34)];
    self.sessionLabel.font = [UIFont systemFontOfSize:11];
    self.sessionLabel.numberOfLines = 2;
    self.sessionLabel.adjustsFontSizeToFitWidth = YES;
    self.sessionLabel.minimumScaleFactor = 0.7;
    self.sessionLabel.userInteractionEnabled = YES;
    [self.sessionLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(refreshSession)]];
    [self.homeView addSubview:self.sessionLabel];

    self.closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    self.closeBtn.frame = CGRectMake(MV_PANEL_W - 84, MV_PANEL_H - 48, 72, 36);
    self.closeBtn.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.closeBtn.layer.cornerRadius = 9;
    self.closeBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.homeView addSubview:self.closeBtn];
}

- (void)refreshVoiceState {
    self.allVoices = [self voiceList];
    self.filteredVoices = self.allVoices;
    NSString *vid = (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
    self.selectedVoiceID = vid;

    NSString *name = @"未选择音色";
    for (NSDictionary *d in self.allVoices) {
        if ([d[@"voiceID"] isEqualToString:vid]) { name = d[@"name"] ?: d[@"voiceID"]; break; }
    }
    NSString *provider = (MVTTSProvider() == 1) ? @"千问" : @"CosyVoice";
    NSString *title = [NSString stringWithFormat:@"选择音色（%@）", provider];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12], NSForegroundColorAttributeName:[UIColor secondaryLabelColor]}];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", name] attributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:15], NSForegroundColorAttributeName:[UIColor labelColor]}]];
    [self.voiceSelectBtn setAttributedTitle:attr forState:UIControlStateNormal];

    if (self.voiceTable) [self.voiceTable reloadData];
}

#pragma mark - 音色选择视图（参考截图）

- (void)buildPickerView {
    self.pickerView = [[UIView alloc] initWithFrame:self.panel.bounds];

    // 标题栏
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MV_PANEL_W, 44)];
    UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 220, 22)];
    pt.text = @"选择音色（千问48+原440）";
    pt.font = [UIFont boldSystemFontOfSize:15];
    pt.textColor = [UIColor labelColor];
    [header addSubview:pt];

    self.reloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.reloadBtn setTitle:@"重新加载" forState:UIControlStateNormal];
    self.reloadBtn.frame = CGRectMake(MV_PANEL_W - 90, 8, 82, 28);
    self.reloadBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [self.reloadBtn addTarget:self action:@selector(onReloadVoices) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.reloadBtn];

    self.pickerBackBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pickerBackBtn setTitle:@"返回" forState:UIControlStateNormal];
    self.pickerBackBtn.frame = CGRectMake(MV_PANEL_W - 180, 8, 80, 28);
    self.pickerBackBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [self.pickerBackBtn addTarget:self action:@selector(hidePicker) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.pickerBackBtn];

    [self.pickerView addSubview:header];

    CGFloat y = 50;

    // 搜索框
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(8, y, MV_PANEL_W - 16, 36)];
    self.searchBar.placeholder = @"搜索音色（中文名/ID，如 Cherry…";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.delegate = self;
    [self.pickerView addSubview:self.searchBar];
    y += 42;

    // 语速
    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 36, 22)];
    sl.text = @"语速";
    sl.font = [UIFont systemFontOfSize:13];
    sl.textColor = [UIColor labelColor];
    [self.pickerView addSubview:sl];

    self.speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(54, y, MV_PANEL_W - 130, 22)];
    self.speedSlider.minimumValue = 0.5f;
    self.speedSlider.maximumValue = 2.0f;
    self.speedSlider.value = (float)MVQwenSpeed();
    [self.speedSlider addTarget:self action:@selector(onSpeedChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerView addSubview:self.speedSlider];

    self.speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(MV_PANEL_W - 68, y, 56, 22)];
    self.speedLabel.font = [UIFont systemFontOfSize:13];
    self.speedLabel.textAlignment = NSTextAlignmentRight;
    self.speedLabel.textColor = [UIColor labelColor];
    [self updateSpeedLabel];
    [self.pickerView addSubview:self.speedLabel];
    y += 30;

    // 语气
    UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 36, 22)];
    el.text = @"语气";
    el.font = [UIFont systemFontOfSize:13];
    el.textColor = [UIColor labelColor];
    [self.pickerView addSubview:el];

    self.emotionSeg = [[UISegmentedControl alloc] initWithItems:@[@"默认", @"生气", @"愤怒", @"快乐", @"开朗"]];
    self.emotionSeg.frame = CGRectMake(54, y, MV_PANEL_W - 68, 28);
    self.emotionSeg.selectedSegmentIndex = [self emotionIndex:MVQwenEmotion()];
    [self.emotionSeg addTarget:self action:@selector(onEmotionChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerView addSubview:self.emotionSeg];
    y += 32;

    // 说明
    self.pickerHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, MV_PANEL_W - 28, 18)];
    self.pickerHintLabel.text = @"语速/语气只对千问音色（第一段）生效";
    self.pickerHintLabel.font = [UIFont systemFontOfSize:11];
    self.pickerHintLabel.textColor = [UIColor tertiaryLabelColor];
    [self.pickerView addSubview:self.pickerHintLabel];
    y += 24;

    // 分组标题
    self.sectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, MV_PANEL_W - 28, 22)];
    self.sectionLabel.text = @"千问（48音色·支持语气/语速）";
    self.sectionLabel.font = [UIFont boldSystemFontOfSize:14];
    self.sectionLabel.textColor = [UIColor labelColor];
    [self.pickerView addSubview:self.sectionLabel];
    y += 26;

    // 音色列表
    self.voiceTable = [[UITableView alloc] initWithFrame:CGRectMake(12, y, MV_PANEL_W - 24, MV_PANEL_H - y - 12) style:UITableViewStylePlain];
    self.voiceTable.backgroundColor = [UIColor clearColor];
    self.voiceTable.dataSource = self;
    self.voiceTable.delegate = self;
    self.voiceTable.layer.cornerRadius = 10;
    self.voiceTable.separatorInset = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.pickerView addSubview:self.voiceTable];
}

- (NSInteger)emotionIndex:(NSString*)emotion {
    NSDictionary *map = @{@"default":@0, @"生气":@1, @"angry":@1, @"愤怒":@2, @"furious":@2,
                          @"快乐":@3, @"happy":@3, @"开朗":@4, @"cheerful":@4};
    return [map[emotion] integerValue];
}

- (NSString*)emotionValueForIndex:(NSInteger)idx {
    NSArray *arr = @[@"default", @"生气", @"愤怒", @"快乐", @"开朗"];
    return arr[idx];
}

- (void)updateSpeedLabel {
    self.speedLabel.text = [NSString stringWithFormat:@"%.2fx", self.speedSlider.value];
}

- (void)onSpeedChanged:(UISlider*)s {
    [self updateSpeedLabel];
    MVSetShared(@"qwenSpeed", @(s.value));
}

- (void)onEmotionChanged:(UISegmentedControl*)seg {
    MVSetShared(@"qwenEmotion", [self emotionValueForIndex:seg.selectedSegmentIndex]);
}

- (void)onReloadVoices {
    [self refreshVoiceState];
    [self.voiceTable reloadData];
    [[MyVoiceManager shared] toast:@"音色列表已刷新"];
}

- (void)showPicker {
    self.homeView.hidden = YES;
    self.pickerView.hidden = NO;
    [self refreshVoiceState];
    [self.searchBar resignFirstResponder];
}

- (void)hidePicker {
    self.pickerView.hidden = YES;
    self.homeView.hidden = NO;
    [self refreshVoiceState];
}

#pragma mark - 搜索

- (void)searchBar:(UISearchBar*)searchBar textDidChange:(NSString*)searchText {
    NSString *q = [searchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    if (!q.length) {
        self.filteredVoices = self.allVoices;
    } else {
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
        cell.backgroundColor = [UIColor systemBackgroundColor];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    NSDictionary *d = self.filteredVoices[(NSUInteger)indexPath.row];
    cell.textLabel.text = d[@"name"] ?: d[@"voiceID"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@ · model: %@", d[@"voiceID"] ?: @"", d[@"model"] ?: @""];
    cell.accessoryType = [d[@"voiceID"] isEqualToString:self.selectedVoiceID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.filteredVoices[(NSUInteger)indexPath.row];
    self.selectedVoiceID = d[@"voiceID"];
    if (MVTTSProvider() == 1) {
        MVSetShared(@"qwenVoice", self.selectedVoiceID);
        MVSetShared(@"qwenModel", d[@"model"] ?: @"qwen3-tts-flash");
    } else {
        MVSetShared(@"currentVoiceID", self.selectedVoiceID);
    }
    [self.voiceTable reloadData];
    [self hidePicker];
}

#pragma mark - 会话/拖动

- (void)refreshSession {
    NSString *s = [[MyVoiceManager shared] talkerStatus];
    BOOL ok = [s rangeOfString:@"未识别"].location == NSNotFound;
    self.sessionLabel.text = [NSString stringWithFormat:@"%@  %@", s, ok ? @"✅" : @"（点我重试）"];
    self.sessionLabel.textColor = ok ? [UIColor systemBlueColor] : [UIColor systemOrangeColor];
}

- (void)startSessionTimer {
    if (self.sessionTimer) return;
    self.sessionTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refreshSession) userInfo:nil repeats:YES];
}
- (void)stopSessionTimer {
    [self.sessionTimer invalidate]; self.sessionTimer = nil;
}

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
    if (self.panel.hidden) {
        [self stopSessionTimer];
    } else {
        [self refreshSession];
        [self refreshVoiceState];
        [self startSessionTimer];
    }
}

- (void)closePanel { self.panel.hidden = YES; [self stopSessionTimer]; }

#pragma mark - 发送/预览/克隆

- (NSString*)resolvedVoiceID {
    NSString *vid = self.selectedVoiceID;
    if (vid.length) return vid;
    return (MVTTSProvider() == 1) ? MVQwenVoice() : MVCurrentVoiceID();
}

#pragma mark - ★ 2.2.7 预合成（消除发送延迟里的合成等待）

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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 发送

- (void)onSend {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) { [[MyVoiceManager shared] toast:@"请先输入文字"]; return; }
    NSString *vid = [self resolvedVoiceID];
    if (MVEngineMode()==1 && MVTTSProvider()==0 && !vid.length) { [[MyVoiceManager shared] toast:@"请先创建一个音色"]; return; }
    if (MVTTSProvider()==0) {
        MVSetShared(@"currentVoiceID", vid);
    }
    [[MyVoiceManager shared] handleSendText:text];
    self.panel.hidden = YES;
    [self stopSessionTimer];
}

- (void)onPreview {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
}

@end
