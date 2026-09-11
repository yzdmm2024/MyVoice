#import "MyVoiceCommon.h"
#import "MyVoiceManager.h"

%ctor {
    @autoreleasepool {
        MVLog(@"载入 我的语音 v1.0.0（离线系统TTS，纯功能，无赞赏/打赏）");
        [[MyVoiceManager shared] setup];
    }
}
