#import "MyVoiceCloneController.h"
#import "MyVoiceCommon.h"
#import "MyVoiceCloud.h"
#import <AVFoundation/AVFoundation.h>

// 音色创建：两种模式
//   0 录音复刻 —— 录一段参考音频（24k 单声道 wav）→ 上传 OSS → CosyVoice 复刻
//   1 文字设计 —— 只给一句描述 → voice_prompt 分支直接生成（不需要录音 / OSS）
@interface MyVoiceCloneController () <AVAudioRecorderDelegate>
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) NSString *recPath;
@property (nonatomic, strong) UIButton *recBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UITextView *promptView;
@property (nonatomic, strong) UITextField *previewField;
@property (nonatomic, strong) UIButton *designBtn;
@property (nonatomic, strong) NSArray *recordViews;
@property (nonatomic, strong) NSArray *designViews;
@end

@implementation MyVoiceCloneController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"音色";
    self.view.backgroundColor = [UIColor secondarySystemBackgroundColor];
    CGFloat W = self.view.bounds.size.width;

    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(20, 100, W-40, 40)];
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.placeholder = @"音色名称（如：我的声音）";
    [self.view addSubview:self.nameField];

    self.modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"录音复刻", @"文字设计"]];
    self.modeSeg.frame = CGRectMake(20, 152, W-40, 32);
    self.modeSeg.selectedSegmentIndex = 0;
    [self.modeSeg addTarget:self action:@selector(updateMode) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeSeg];

    // ---- 模式 0：录音复刻 ----
    self.recBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.recBtn setTitle:@"开始录音（15~30秒安静干声）" forState:UIControlStateNormal];
    self.recBtn.backgroundColor = [UIColor systemBlueColor];
    [self.recBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.recBtn.frame = CGRectMake(20, 210, W-40, 48);
    self.recBtn.layer.cornerRadius = 10;
    [self.recBtn addTarget:self action:@selector(toggleRec) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.recBtn];
    self.recordViews = @[self.recBtn];

    // ---- 模式 1：文字设计 ----
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, 198, W-40, 18)];
    tip.text = @"用一句话描述想要的声音"; tip.font = [UIFont systemFontOfSize:13];
    tip.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:tip];

    self.promptView = [[UITextView alloc] initWithFrame:CGRectMake(20, 220, W-40, 90)];
    self.promptView.layer.cornerRadius = 8; self.promptView.font = [UIFont systemFontOfSize:15];
    self.promptView.backgroundColor = [UIColor systemBackgroundColor];
    self.promptView.text = @"沉稳的中年男性播音员，音色低沉浑厚，语速平稳，吐字清晰";
    [self.view addSubview:self.promptView];

    self.previewField = [[UITextField alloc] initWithFrame:CGRectMake(20, 318, W-40, 40)];
    self.previewField.borderStyle = UITextBorderStyleRoundedRect;
    self.previewField.placeholder = @"试听文本（可留空）";
    [self.view addSubview:self.previewField];

    self.designBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.designBtn setTitle:@"生成音色" forState:UIControlStateNormal];
    self.designBtn.backgroundColor = [UIColor systemBlueColor];
    [self.designBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.designBtn.frame = CGRectMake(20, 368, W-40, 48);
    self.designBtn.layer.cornerRadius = 10;
    [self.designBtn addTarget:self action:@selector(doDesign) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.designBtn];
    self.designViews = @[tip, self.promptView, self.previewField, self.designBtn];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 262, W-40, 120)];
    self.statusLabel.numberOfLines = 0; self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.statusLabel];

    self.recPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mv_clone.wav"];

    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(dismiss)];
    UIBarButtonItem *test = [[UIBarButtonItem alloc] initWithTitle:@"测试配置"
        style:UIBarButtonItemStylePlain target:self action:@selector(testKey)];
    self.navigationItem.rightBarButtonItems = @[close, test];

    [self updateMode];
}

// 一键自检：先确认设置里的 Key 是否真的被微信进程读到了（跨进程读取），再验证 Key 有效
- (void)testKey {
    NSString *key = MVAPIKey();
    if (!key.length) {
        self.statusLabel.text = [NSString stringWithFormat:
            @"❌ 没读到 API Key。\n\n读取来源自检：\n%@\n\n"
            @"如果 ① 不是「有」，说明设置还没写进越狱共享文件：\n"
            @"· 到「设置 → 我的语音」把 Key 重填一次\n"
            @"· 点一下那里的「测试 API Key 是否可用」（这一步会触发落盘）\n"
            @"· 再回这里点「测试配置」", MVReadDiag()];
        return;
    }
    self.statusLabel.text = [NSString stringWithFormat:
        @"已读到 API Key：…%@（共 %lu 位）\n\n读取来源自检：\n%@\n\n正在测试接口…",
        [key substringFromIndex:MAX(0, (NSInteger)key.length - 4)],
        (unsigned long)key.length, MVReadDiag()];
    __weak typeof(self) ws = self;
    [[MyVoiceCloud shared] testAPIKeyWithCompletion:^(BOOL ok, NSString *msg){
        __strong typeof(ws) self = ws;
        if (!self) return;
        self.statusLabel.text = [NSString stringWithFormat:@"%@\n\n%@", ok ? @"✅ 配置可用" : @"❌ 配置有问题", msg];
    }];
}

// 切换模式：显隐对应控件 + 下移状态栏 + 给出当前模式的就绪提示
- (void)updateMode {
    BOOL design = (self.modeSeg.selectedSegmentIndex == 1);
    for (UIView *v in self.recordViews) v.hidden = design;
    for (UIView *v in self.designViews)  v.hidden = !design;

    CGRect f = self.statusLabel.frame;
    f.origin.y = design ? 428 : 272;
    self.statusLabel.frame = f;

    if (!MVAPIKey().length) {
        self.statusLabel.text = @"⚠️ 请先在 设置→我的语音 填写 DashScope API Key";
        return;
    }
    // ★ 2.4.0：录音复刻改走 DashScope 临时托管，不再要求 OSS（配了自有 OSS 会优先用）
    self.statusLabel.text = design
        ? @"填一句音色描述，点「生成音色」。约 10~30 秒。\n不需要录音，也不需要 OSS。"
        : @"点「开始录音」，读 15~30 秒安静干声，松手自动复刻。\n只需 API Key，无需配置 OSS。";
}

- (void)toggleRec {
    if (self.recorder && self.recorder.isRecording) { [self.recorder stop]; return; }
    if (!MVAPIKey().length) {
        self.statusLabel.text = @"⚠️ 录音复刻需要先在 设置→我的语音 填写 DashScope API Key";
        return;
    }
    NSError *e = nil;
    NSDictionary *set = @{
        AVSampleRateKey: @24000,
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsFloatKey: @NO
    };
    [[NSFileManager defaultManager] removeItemAtPath:self.recPath error:nil];
    self.recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:self.recPath]
                                                 settings:set error:&e];
    if (e || !self.recorder) { self.statusLabel.text = [@"录音初始化失败：" stringByAppendingString:e.localizedDescription]; return; }
    self.recorder.delegate = self;
    [self.recorder record];
    [self.recBtn setTitle:@"停止录音" forState:UIControlStateNormal];
    self.statusLabel.text = @"录音中…";
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder*)recorder successfully:(BOOL)ok {
    [self.recBtn setTitle:@"开始录音（15~30秒安静干声）" forState:UIControlStateNormal];
    if (!ok) { self.statusLabel.text = @"录音失败"; return; }
    self.statusLabel.text = @"录音完成，正在上传托管并复刻…";
    NSString *name = self.nameField.text.length ? self.nameField.text : @"我的声音";
    NSString *model = MVCurrentModel();
    [[MyVoiceCloud shared] cloneVoiceWithName:name referenceAudioPath:self.recPath
        completion:^(NSString *voiceID, NSError *err){
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!voiceID) { self.statusLabel.text = [@"克隆失败：" stringByAppendingString:err.localizedDescription]; return; }
                [self saveVoice:name voiceID:voiceID model:model];
                self.statusLabel.text = [NSString stringWithFormat:@"✅ 克隆成功：%@\nvoice_id=%@", name, voiceID];
            });
        }];
}

- (void)doDesign {
    NSString *prompt = [self.promptView.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!prompt.length) { self.statusLabel.text = @"⚠️ 请先填写音色描述"; return; }
    if (!MVAPIKey().length) {
        self.statusLabel.text = @"⚠️ 请先在 设置→我的语音 填写 DashScope API Key";
        return;
    }
    NSString *name = self.nameField.text.length ? self.nameField.text : @"设计音色";
    NSString *preview = [self.previewField.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.designBtn.enabled = NO;
    self.statusLabel.text = @"正在生成音色，约 10~30 秒…";
    [[MyVoiceCloud shared] designVoiceWithName:name prompt:prompt previewText:preview
        completion:^(NSString *voiceID, NSError *err){
            dispatch_async(dispatch_get_main_queue(), ^{
                self.designBtn.enabled = YES;
                if (!voiceID) {
                    self.statusLabel.text = [@"生成失败：" stringByAppendingString:err.localizedDescription];
                    return;
                }
                [self saveVoice:name voiceID:voiceID model:MVDesignModel()];
                self.statusLabel.text = [NSString stringWithFormat:@"✅ 生成成功：%@\nvoice_id=%@\n\n回悬浮球面板选它即可。", name, voiceID];
            });
        }];
}

- (void)saveVoice:(NSString*)name voiceID:(NSString*)voiceID model:(NSString*)model {
    NSMutableArray *vs = [NSMutableArray arrayWithArray:MVVoices()];
    [vs addObject:@{@"name": name, @"voiceID": voiceID, @"model": model}];
    [MVPrefs() setObject:vs forKey:@"voices"];
    [MVPrefs() setObject:voiceID forKey:@"currentVoiceID"];
    [MVPrefs() synchronize];
    MVLog(@"[clone] 已保存音色 %@ -> %@ (%@)", name, voiceID, model);
}

- (void)dismiss { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
