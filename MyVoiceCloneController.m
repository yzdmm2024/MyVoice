#import "MyVoiceCloneController.h"
#import "MyVoiceCommon.h"
#import "MyVoiceCloud.h"
#import <AVFoundation/AVFoundation.h>

@interface MyVoiceCloneController () <AVAudioRecorderDelegate>
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) NSString *recPath;
@property (nonatomic, strong) UIButton *recBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *nameField;
@end

@implementation MyVoiceCloneController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"克隆我的音色";
    self.view.backgroundColor = [UIColor secondarySystemBackgroundColor];

    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(20, 90, self.view.bounds.size.width-40, 40)];
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.placeholder = @"音色名称（如：我的声音）";
    [self.view addSubview:self.nameField];

    self.recBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.recBtn setTitle:@"开始录音（15~30秒安静干声）" forState:UIControlStateNormal];
    self.recBtn.backgroundColor = [UIColor systemBlueColor];
    [self.recBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.recBtn.frame = CGRectMake(20, 150, self.view.bounds.size.width-40, 48);
    self.recBtn.layer.cornerRadius = 10;
    [self.recBtn addTarget:self action:@selector(toggleRec) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.recBtn];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 210, self.view.bounds.size.width-40, 60)];
    self.statusLabel.numberOfLines = 0; self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.statusLabel];

    self.recPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mv_clone.wav"];

    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStyleDone target:self action:@selector(dismiss)];
    self.navigationItem.rightBarButtonItem = close;

    if (!MVAPIKey().length || !MVWorkspace().length) {
        self.statusLabel.text = @"⚠️ 请先在 设置→我的语音 填写 DashScope API Key 与 workspace";
    } else if (!MVOSSBucket().length) {
        self.statusLabel.text = @"⚠️ 请先在 设置→我的语音 填写 OSS（克隆需托管参考音频）";
    }
}

- (void)toggleRec {
    if (self.recorder && self.recorder.isRecording) { [self.recorder stop]; return; }
    if (!MVAPIKey().length || !MVWorkspace().length || !MVOSSBucket().length) {
        self.statusLabel.text = @"⚠️ 请先在设置里配置 API Key / workspace / OSS";
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
    [self.recBtn setTitle:@"开始录音" forState:UIControlStateNormal];
    if (!ok) { self.statusLabel.text = @"录音失败"; return; }
    self.statusLabel.text = @"录音完成，正在克隆…";
    NSString *name = self.nameField.text.length ? self.nameField.text : @"我的声音";
    [[MyVoiceCloud shared] cloneVoiceWithName:name referenceAudioPath:self.recPath
        completion:^(NSString *voiceID, NSError *err){
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!voiceID) { self.statusLabel.text = [@"克隆失败：" stringByAppendingString:err.localizedDescription]; return; }
                [self saveVoice:name voiceID:voiceID];
                self.statusLabel.text = [NSString stringWithFormat:@"✅ 克隆成功：%@\nvoice_id=%@", name, voiceID];
            });
        }];
}

- (void)saveVoice:(NSString*)name voiceID:(NSString*)voiceID {
    NSMutableArray *vs = [NSMutableArray arrayWithArray:MVVoices()];
    [vs addObject:@{@"name": name, @"voiceID": voiceID, @"model": MVCurrentModel()}];
    [MVPrefs() setObject:vs forKey:@"voices"];
    [MVPrefs() setObject:voiceID forKey:@"currentVoiceID"];
    [MVPrefs() synchronize];
    MVLog(@"[clone] 已保存音色 %@ -> %@", name, voiceID);
}

- (void)dismiss { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
