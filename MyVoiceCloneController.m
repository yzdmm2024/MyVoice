#import "MyVoiceCloneController.h"
#import "MyVoiceCommon.h"
#import "MyVoiceCloud.h"
#import <AVFoundation/AVFoundation.h>

// 音色创建：三种模式（★ 2.4.2 新增「上传音频」）
//   0 录音复刻 —— 现场录一段参考音频 → DashScope 临时托管（免 OSS）→ CosyVoice 复刻
//   1 上传音频 —— 从文件里选一段想克隆的声音（wav/mp3/m4a…）→ 同上
//   2 文字设计 —— 只给一句描述 → voice_prompt 分支直接生成（不需要音频 / OSS）
@interface MyVoiceCloneController () <AVAudioRecorderDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) NSString *recPath;
@property (nonatomic, strong) NSString *uploadPath;   // 选中的音频文件
@property (nonatomic, strong) NSString *uploadName;   // 原始文件名（展示用）
@property (nonatomic, strong) UIButton *recBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UITextView *promptView;
@property (nonatomic, strong) UITextField *previewField;
@property (nonatomic, strong) UIButton *designBtn;
@property (nonatomic, strong) UIButton *pickBtn;
@property (nonatomic, strong) UILabel *pickedLabel;
@property (nonatomic, strong) UIButton *uploadBtn;
@property (nonatomic, strong) NSArray *recordViews;
@property (nonatomic, strong) NSArray *designViews;
@property (nonatomic, strong) NSArray *uploadViews;
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

    self.modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"录音复刻", @"上传音频", @"文字设计"]];
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

    // ---- 模式 1：上传音频复刻（★ 2.4.2）----
    self.pickBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pickBtn setTitle:@"从文件选取音频（wav / mp3 / m4a…）" forState:UIControlStateNormal];
    self.pickBtn.backgroundColor = [UIColor systemBlueColor];
    [self.pickBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.pickBtn.frame = CGRectMake(20, 210, W-40, 48);
    self.pickBtn.layer.cornerRadius = 10;
    [self.pickBtn addTarget:self action:@selector(pickAudio) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.pickBtn];

    self.pickedLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 264, W-40, 18)];
    self.pickedLabel.font = [UIFont systemFontOfSize:12];
    self.pickedLabel.textColor = [UIColor secondaryLabelColor];
    self.pickedLabel.text = @"尚未选择文件";
    [self.view addSubview:self.pickedLabel];

    self.uploadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.uploadBtn setTitle:@"开始克隆" forState:UIControlStateNormal];
    self.uploadBtn.backgroundColor = [UIColor systemBlueColor];
    [self.uploadBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.uploadBtn.frame = CGRectMake(20, 288, W-40, 48);
    self.uploadBtn.layer.cornerRadius = 10;
    [self.uploadBtn addTarget:self action:@selector(doUploadClone) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.uploadBtn];
    self.uploadViews = @[self.pickBtn, self.pickedLabel, self.uploadBtn];

    // ---- 模式 2：文字设计 ----
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
    NSInteger idx = self.modeSeg.selectedSegmentIndex;   // 0录音 1上传 2文字设计
    BOOL design = (idx == 2), upload = (idx == 1);
    for (UIView *v in self.recordViews) v.hidden = (idx != 0);
    for (UIView *v in self.uploadViews) v.hidden = !upload;
    for (UIView *v in self.designViews) v.hidden = !design;

    CGRect f = self.statusLabel.frame;
    f.origin.y = design ? 428 : (upload ? 344 : 272);
    self.statusLabel.frame = f;

    if (!MVAPIKey().length) {
        self.statusLabel.text = @"⚠️ 请先在 设置→我的语音 填写 DashScope API Key";
        return;
    }
    self.statusLabel.text = design
        ? @"填一句音色描述，点「生成音色」。约 10~30 秒。\n不需要录音，也不需要 OSS。"
        : (upload
           ? @"选一段安静、清晰、15~30 秒的目标声音音频\n（比如对方的语音备忘录），点「开始克隆」。"
           : @"点「开始录音」，读 15~30 秒安静干声，松手自动复刻。\n只需 API Key，无需配置 OSS。");
}

// ★ 2.4.2：从文件选音频（文件 App / iCloud / 各 App 导出的音频都能选）
- (void)pickAudio {
    // initForContentTypes 需要 UTI 框架；这里用旧 API（已在 CFLAGS 里压掉弃用告警），行为一致
    UIDocumentPickerViewController *dp =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio", @"public.data"]
                                                               inMode:UIDocumentPickerModeOpen];
    dp.delegate = self;
    dp.allowsMultipleSelection = NO;
    [self presentViewController:dp animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
  didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (!urls.count) return;
    NSURL *src = urls.firstObject;
    // ★ 修复：安全作用域资源必须先 startAccessing 才能读取
    [src startAccessingSecurityScopedResource];
    NSString *ext = src.pathExtension.length ? src.pathExtension.lowercaseString : @"wav";
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"mv_upload_%@.%@", [[NSUUID UUID] UUIDString], ext]];
    NSError *e = nil;
    [[NSFileManager defaultManager] copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&e];
    [src stopAccessingSecurityScopedResource];
    if (e) { self.statusLabel.text = [@"读取文件失败：" stringByAppendingString:e.localizedDescription]; return; }
    self.uploadPath = dst;
    self.uploadName = src.lastPathComponent;
    // 显示文件名与时长（读不出时长就只显示文件名）
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:dst] options:nil];
    double dur = CMTimeGetSeconds(asset.duration);
    if (dur > 0) self.pickedLabel.text = [NSString stringWithFormat:@"已选择：%@（%.1f 秒）", self.uploadName, dur];
    else         self.pickedLabel.text = [NSString stringWithFormat:@"已选择：%@", self.uploadName];
    self.statusLabel.text = @"";
}

- (void)doUploadClone {
    if (!self.uploadPath.length) { self.statusLabel.text = @"⚠️ 请先点上方按钮选择音频文件"; return; }
    if (!MVAPIKey().length) {
        self.statusLabel.text = @"⚠️ 请先在 设置→我的语音 填写 DashScope API Key";
        return;
    }
    NSString *name = self.nameField.text.length ? self.nameField.text : @"克隆音色";
    self.uploadBtn.enabled = NO;
    self.statusLabel.text = @"正在上传托管并复刻，约 10~30 秒…";
    __weak typeof(self) ws = self;
    NSString *model = MVCurrentModel();
    [[MyVoiceCloud shared] cloneVoiceWithName:name referenceAudioPath:self.uploadPath
        completion:^(NSString *voiceID, NSError *err){
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(ws) self = ws;
                if (!self) return;
                self.uploadBtn.enabled = YES;
                if (!voiceID) {
                    self.statusLabel.text = [@"克隆失败：" stringByAppendingString:err.localizedDescription];
                    return;
                }
                [self saveVoice:name voiceID:voiceID model:model];
                self.statusLabel.text = [NSString stringWithFormat:
                    @"✅ 克隆成功：%@\nvoice_id=%@\n\n到音色列表选它即可（我的克隆段）。", name, voiceID];
            });
        }];
}

- (void)toggleRec {
    if (self.recorder && self.recorder.isRecording) {
        [self.recorder stop];
        // 安全超时：delegate 2 秒不回调就手动处理
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.statusLabel.text.length && [self.statusLabel.text containsString:@"录音中…"]) {
                self.statusLabel.text = @"录音停止超时，请重试";
                [self.recBtn setTitle:@"开始录音（15~30秒安静干声）" forState:UIControlStateNormal];
            }
        });
        return;
    }
    if (!MVAPIKey().length) {
        self.statusLabel.text = @"⚠️ 录音复刻需要先在 设置→我的语音 填写 DashScope API Key";
        return;
    }
    // ★ 激活 AudioSession（QQ 进程里必须，否则 AVAudioRecorder 不工作）
    NSError *se = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                            mode:AVAudioSessionModeDefault
                                         options:0 error:&se];
    [[AVAudioSession sharedInstance] setActive:YES error:&se];

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
    if (![self.recorder record]) {
        self.statusLabel.text = @"录音启动失败（音频会话冲突）";
        return;
    }
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
