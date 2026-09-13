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
// ★ 2.8.6
@property (nonatomic, strong) UISegmentedControl *modelSeg;
@property (nonatomic, strong) UILabel *modelHint;
@property (nonatomic, strong) UISwitch *preprocSwitch;
@property (nonatomic, strong) UILabel *preprocLabel;
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

    // ---- ★ 2.8.6：复刻模型（决定这个音色以后能说哪些方言）----
    //   voice_id 与复刻时的 target_model 强绑定，选错了要么方言说不了，要么合成直接失败。
    UILabel *mLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 192, W-40, 16)];
    mLabel.text = @"复刻模型（决定以后能说哪些方言）";
    mLabel.font = [UIFont systemFontOfSize:12];
    mLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:mLabel];

    self.modelSeg = [[UISegmentedControl alloc] initWithItems:MVCosyModelLabels()];
    self.modelSeg.frame = CGRectMake(20, 210, W-40, 30);
    self.modelSeg.selectedSegmentIndex = MVCosyModelIndex(MVCosyModel());
    [self.modelSeg addTarget:self action:@selector(onModelChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modelSeg];

    self.modelHint = [[UILabel alloc] initWithFrame:CGRectMake(20, 244, W-40, 16)];
    self.modelHint.font = [UIFont systemFontOfSize:11];
    self.modelHint.textColor = [UIColor tertiaryLabelColor];
    [self.view addSubview:self.modelHint];

    self.preprocLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 264, W-160, 26)];
    self.preprocLabel.text = @"音频降噪增强";
    self.preprocLabel.font = [UIFont systemFontOfSize:13];
    self.preprocLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.preprocLabel];

    self.preprocSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(W-72, 262, 51, 31)];
    self.preprocSwitch.on = MVClonePreprocess();
    self.preprocSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self.preprocSwitch addTarget:self action:@selector(onPreprocChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.preprocSwitch];

    // ---- 模式 0：录音复刻 ----
    self.recBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.recBtn setTitle:@"开始录音（15~30秒安静干声）" forState:UIControlStateNormal];
    self.recBtn.backgroundColor = [UIColor systemBlueColor];
    [self.recBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.recBtn.frame = CGRectMake(20, 290, W-40, 48);
    self.recBtn.layer.cornerRadius = 10;
    [self.recBtn addTarget:self action:@selector(toggleRec) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.recBtn];
    self.recordViews = @[self.recBtn];

    // ---- 模式 1：上传音频复刻（★ 2.4.2）----
    self.pickBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pickBtn setTitle:@"从文件选取音频（wav / mp3 / m4a / aud…）" forState:UIControlStateNormal];
    self.pickBtn.backgroundColor = [UIColor systemBlueColor];
    [self.pickBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.pickBtn.frame = CGRectMake(20, 290, W-40, 48);
    self.pickBtn.layer.cornerRadius = 10;
    [self.pickBtn addTarget:self action:@selector(pickAudio) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.pickBtn];

    self.pickedLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 344, W-40, 18)];
    self.pickedLabel.font = [UIFont systemFontOfSize:12];
    self.pickedLabel.textColor = [UIColor secondaryLabelColor];
    self.pickedLabel.text = @"尚未选择文件";
    [self.view addSubview:self.pickedLabel];

    self.uploadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.uploadBtn setTitle:@"开始克隆" forState:UIControlStateNormal];
    self.uploadBtn.backgroundColor = [UIColor systemBlueColor];
    [self.uploadBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.uploadBtn.frame = CGRectMake(20, 368, W-40, 48);
    self.uploadBtn.layer.cornerRadius = 10;
    [self.uploadBtn addTarget:self action:@selector(doUploadClone) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.uploadBtn];
    self.uploadViews = @[self.pickBtn, self.pickedLabel, self.uploadBtn];

    // ---- 模式 2：文字设计 ----
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, 278, W-40, 18)];
    tip.text = @"用一句话描述想要的声音"; tip.font = [UIFont systemFontOfSize:13];
    tip.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:tip];

    self.promptView = [[UITextView alloc] initWithFrame:CGRectMake(20, 300, W-40, 90)];
    self.promptView.layer.cornerRadius = 8; self.promptView.font = [UIFont systemFontOfSize:15];
    self.promptView.backgroundColor = [UIColor systemBackgroundColor];
    self.promptView.text = @"沉稳的中年男性播音员，音色低沉浑厚，语速平稳，吐字清晰";
    [self.view addSubview:self.promptView];

    self.previewField = [[UITextField alloc] initWithFrame:CGRectMake(20, 398, W-40, 40)];
    self.previewField.borderStyle = UITextBorderStyleRoundedRect;
    self.previewField.placeholder = @"试听文本（可留空）";
    [self.view addSubview:self.previewField];

    self.designBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.designBtn setTitle:@"生成音色" forState:UIControlStateNormal];
    self.designBtn.backgroundColor = [UIColor systemBlueColor];
    [self.designBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.designBtn.frame = CGRectMake(20, 448, W-40, 48);
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
    f.origin.y = design ? 508 : (upload ? 424 : 352);
    self.statusLabel.frame = f;

    if (!MVAPIKey().length) {
        self.statusLabel.text = @"⚠️ 请先在 设置→我的语音 填写 DashScope API Key";
        return;
    }
    [self refreshModelHint];
    self.statusLabel.text = design
        ? @"填一句音色描述，点「生成音色」。约 10~30 秒。\n不需要录音，也不需要 OSS。"
        : (upload
           ? @"选一段安静、清晰、10~60 秒的目标声音音频（支持 wav/mp3/m4a）。\n"
             @"整段是同一个人连续说话时相似度最高；\n"
             @"若是把多段短句拼起来的文件也能复刻，但相似度会打折。点「开始克隆」。"
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
    // ★ 2.8.9：.aud 支持。微信/QQ 导出的 .aud 通常是 AMR（#!AMR 头）或 SILK（#!SILK 头）封装，
    //   直接拿去上传服务端不认、AVFoundation 也嗅探不出容器 —— 先看魔数再决定走哪条路。
    if ([ext isEqualToString:@"aud"] || [ext isEqualToString:@"amr"]) {
        NSData *head = [NSData dataWithContentsOfFile:src.path options:NSDataReadingMappedIfSafe error:nil];
        NSString *magic = head ? [[NSString alloc] initWithData:
                                [head subdataWithRange:NSMakeRange(0, MIN(16, head.length))]
                                              encoding:NSUTF8StringEncoding] : nil;
        if ([magic hasPrefix:@"#!SILK"]) {
            // SILK 是腾讯私有语音流，iOS 无系统解码器，本地转不了，明确告知怎么办
            [src stopAccessingSecurityScopedResource];
            self.uploadPath = nil;
            self.uploadName = src.lastPathComponent;
            self.pickedLabel.text = [NSString stringWithFormat:@"已选择：%@", self.uploadName];
            self.statusLabel.text = @"❌ 这是 SILK 封装的 .aud（微信/QQ 原始语音流），iOS 没有系统解码器，本机转不了。\n"
                                     @"请先用电脑转成 mp3/wav 再选：\n"
                                     @"ffmpeg -i 文件.aud 文件.mp3  （或用格式工厂）";
            return;
        }
        if ([magic hasPrefix:@"#!AMR"]) ext = @"amr";   // 强制按 amr 落盘，帮 AVFoundation 认容器
    }
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"mv_upload_%@.%@", [[NSUUID UUID] UUIDString], ext]];
    NSError *e = nil;
    [[NSFileManager defaultManager] copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&e];
    [src stopAccessingSecurityScopedResource];
    if (e) { self.statusLabel.text = [@"读取文件失败：" stringByAppendingString:e.localizedDescription]; return; }

    if ([ext isEqualToString:@"amr"]) {
        // ★ 2.8.9：AMR（含 .aud 改名来的）iOS 能解 AMR-NB —— 就地转 m4a 再走克隆链路
        [self transcodeToM4a:dst originalName:src.lastPathComponent];
        return;
    }
    [self finalizePickedPath:dst name:src.lastPathComponent];
}

// ★ 2.8.9：AMR/.aud → m4a。AVAssetExportSession 转码完成后接原有的时长校验逻辑。
- (void)transcodeToM4a:(NSString*)amrPath originalName:(NSString*)name {
    self.uploadPath = nil;
    self.uploadName = name;
    self.pickedLabel.text = [NSString stringWithFormat:@"已选择：%@", name];
    self.statusLabel.text = @"正在把 .aud（AMR）转成 m4a…";
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:amrPath] options:nil];
    AVAssetExportSession *ex = [AVAssetExportSession exportSessionWithAsset:asset
                                                                 presetName:AVAssetExportPresetAppleM4A];
    if (!ex) { [self audConvertFailed]; return; }
    ex.outputFileType = AVFileTypeAppleM4A;
    // export 不会覆盖已存在文件，先删占位
    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"mv_aud_%@.m4a", [[NSUUID UUID] UUIDString]]];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    ex.outputURL = [NSURL fileURLWithPath:out];
    __weak typeof(self) ws = self;
    [ex exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self = ws;
            if (!self) return;
            if (ex.status == AVAssetExportSessionStatusCompleted) {
                NSString *shown = name.pathExtension.length ? [name stringByDeletingPathExtension] : name;
                self.statusLabel.text = @"";
                [self finalizePickedPath:out name:[shown stringByAppendingPathExtension:@"m4a"]];
            } else {
                MVLog(@"[aud] 转码失败 status=%ld err=%@", (long)ex.status, ex.error);
                [self audConvertFailed];
            }
        });
    }];
}

- (void)audConvertFailed {
    self.uploadPath = nil;
    self.statusLabel.text = @"❌ .aud（AMR）转换失败：iOS 解不出这段音频（可能是 AMR-WB / 已损坏）。\n"
                            @"请先用电脑转成 mp3/wav 再选：\n"
                            @"ffmpeg -i 文件.aud 文件.mp3  （或用格式工厂）";
}

// ★ 2.8.9：从 documentPicker 拆出来的收尾逻辑（时长校验），供普通音频与 aud 转码两条路共用
- (void)finalizePickedPath:(NSString*)dst name:(NSString*)name {
    self.uploadPath = dst;
    self.uploadName = name;
    // 显示文件名与时长（读不出时长就只显示文件名）
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:dst] options:nil];
    // ★ 2.8.6：参考音频时长校验。官方 voice-enrollment 的 max_prompt_audio_length
    //   取值范围是 [3.0, 30.0] 秒 —— 短于 3 秒提不出声纹，长于 30 秒只会被截一段用。
    //   以前不校验，用户拿几秒的碎句去复刻，出来不像还以为是插件坏了。
    double dur = CMTimeGetSeconds(asset.duration);
    if (dur <= 0 || dur != dur) {           // 读不出时长（无头 mp3 / 损坏容器）
        self.pickedLabel.text = [NSString stringWithFormat:@"已选择：%@", self.uploadName];
        self.statusLabel.text = @"⚠️ 读不出音频时长，无法校验。仍可试克隆，但建议换成 wav / m4a 再试。";
        return;
    }
    self.pickedLabel.text = [NSString stringWithFormat:@"已选择：%@（%.1f 秒）", self.uploadName, dur];
    if (dur < 3.0) {
        self.uploadPath = nil;              // 直接拦下，别浪费一次复刻额度
        self.statusLabel.text = [NSString stringWithFormat:
            @"❌ 只有 %.1f 秒，太短（官方下限 3 秒），提不出声纹。\n"
            @"请选一段【同一个人连续说话、安静无 BGM】的 10~30 秒音频。", dur];
    } else if (dur > 60.0) {
        self.statusLabel.text = [NSString stringWithFormat:
            @"⚠️ %.1f 秒偏长，服务端只会取一小段做声纹。\n"
            @"建议自己先裁到 20~30 秒（当前取 %.0f 秒），相似度更稳。", dur, MVCloneMaxLen()];
    } else if (dur > 30.0) {
        self.statusLabel.text = [NSString stringWithFormat:
            @"✅ 已选择（%.1f 秒）。超过 30 秒部分不会用到，服务端取 %.0f 秒。", dur, MVCloneMaxLen()];
    } else {
        self.statusLabel.text = @"";
    }
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
    NSString *model = MVCosyModel();
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
                    @"✅ 克隆成功：%@\nvoice_id=%@\n\n已自动切换到该音色，回面板直接发就是它了。", name, voiceID];
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
    NSString *model = MVCosyModel();
    [[MyVoiceCloud shared] cloneVoiceWithName:name referenceAudioPath:self.recPath
        completion:^(NSString *voiceID, NSError *err){
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!voiceID) { self.statusLabel.text = [@"克隆失败：" stringByAppendingString:err.localizedDescription]; return; }
                [self saveVoice:name voiceID:voiceID model:model];
                self.statusLabel.text = [NSString stringWithFormat:
                    @"✅ 克隆成功：%@\nvoice_id=%@\n\n已自动切换到该音色，回面板直接发就是它了。", name, voiceID];
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
                self.statusLabel.text = [NSString stringWithFormat:
                    @"✅ 生成成功：%@\nvoice_id=%@\n\n已自动切换到该音色，回面板直接发就是它了。", name, voiceID];
            });
        }];
}

#pragma mark - ★ 2.8.6 新增

// 切换复刻模型：立刻落盘（MVCosyModel 读的就是这个键），并刷新方言能力提示
- (void)onModelChanged:(UISegmentedControl*)seg {
    NSArray *list = MVCosyModelList();
    NSInteger i = seg.selectedSegmentIndex;
    if (i < 0 || i >= (NSInteger)list.count) return;
    MVSetShared(@"cosyModel", list[(NSUInteger)i]);
    [self refreshModelHint];
}

// 提示这个模型以后能说哪些方言 —— 这是"复刻完发现说不了方言"的唯一预防点
- (void)refreshModelHint {
    if (!self.modelHint) return;
    NSString *m = MVCosyModel();
    NSArray *ds = MVDialectListForModel(m);
    if (!ds.count) {
        self.modelHint.text = [NSString stringWithFormat:@"%@ · 不支持方言指令", m];
        return;
    }
    NSString *note = [m hasPrefix:@"qwen-audio-3.0-tts"] ? @"（含湖南话/重庆话）" : @"";
    self.modelHint.text = [NSString stringWithFormat:@"%@ · 可用方言 %lu 种%@",
                           m, (unsigned long)ds.count, note];
}

- (void)onPreprocChanged:(UISwitch*)sw { MVSetShared(@"clonePreprocess", @(sw.on)); }

// 克隆成功就地试听：不必回面板发一条才知道像不像
- (void)auditionVoice:(NSString*)voiceID {
    if (!voiceID.length) return;
    if (MVEngineMode() != 1 || !MVAPIKey().length) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [MyVoiceEngine previewText:@"这个是新克隆的音色，你听一下，像不像。" voiceID:voiceID];
    });
}

- (void)saveVoice:(NSString*)name voiceID:(NSString*)voiceID model:(NSString*)model {
    if (!voiceID.length) return;
    if (!model.length) model = MVCosyModel();

    // ★ 2.8.4 修掉「克隆没效果」的真 bug：
    //   ① 旧实现只写 currentVoiceID、**不写 ttsProvider**。而 ttsProvider 默认 = 1（千问），
    //      MyVoiceSender 里 `vid = (MVTTSProvider()==1) ? MVQwenVoice() : MVCurrentVoiceID();`
    //      —— provider 还是 1 时，永远用千问预置音色，克隆出来的 voice_id 完全不参与合成。
    //      这就是"克隆完了发出去还是原来那个声音（普通话）"的直接原因。
    //      修法：复刻/设计成功后【自动切到 CosyVoice + 选中新音色】，克隆立刻生效，不用手动再点一次。
    //   ② 音色 item 里的 model 必须等于复刻时的 target_model（MVCosyModel），否则合成会失败。
    //   ③ 同名音色不再无限堆叠，按 name 覆盖更新，列表保持干净。
    NSMutableArray *vs = [NSMutableArray arrayWithArray:MVVoices()];
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"name"]    = name.length ? name : @"克隆音色";
    entry[@"voiceID"] = voiceID;
    entry[@"model"]   = model;
    NSInteger same = -1;
    for (NSUInteger i = 0; i < vs.count; i++) {
        NSDictionary *x = vs[i];
        if ([x isKindOfClass:[NSDictionary class]] && [x[@"name"] isEqual:entry[@"name"]]) {
            same = (NSInteger)i; break;
        }
    }
    if (same >= 0) vs[(NSUInteger)same] = entry; else [vs addObject:entry];

    MVSetShared(@"voices", vs);
    MVSetShared(@"currentVoiceID", voiceID);
    MVSetShared(@"ttsProvider", @0);    // ★ 关键：切到 CosyVoice，克隆才会被用上
    MVSetShared(@"cosyModel", model);   // 复刻 / 合成统一用这个模型
    MVLog(@"[clone] 已保存音色 %@ -> %@ (%@)，并自动切换 ttsProvider=0", entry[@"name"], voiceID, model);
    // ★ 2.8.6：存完立刻试听一句（合成走刚选中的音色）
    [self auditionVoice:voiceID];
}

- (void)dismiss { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
