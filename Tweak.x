#import "MyVoiceCommon.h"
#import "MyVoiceManager.h"

%ctor {
    @autoreleasepool {
        MVLog(@"载入 我的语音 v2.0.0（克隆音色 + SILK 直发，修复 8.0.76 没声音）");
        [[MyVoiceManager shared] setup];
    }
}
