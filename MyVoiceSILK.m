#import "MyVoiceSILK.h"
#import "MyVoiceCommon.h"
#import <dlfcn.h>

// SILK_SDK_SRC 标准编码控制结构（v1.0.x，8 个 int = 32 字节）。
// 字段顺序严格对应 Skype SILK SDK，微信内嵌版本同构。
typedef struct {
    int API_sampleRate;
    int maxInternalSampleRate;
    int packetSize;
    int packetLossPercentage;
    int useInBandFEC;
    int useDTX;
    int complexity;
    int bitRate;
} mv_silk_enc_ctrl;

typedef struct silk_encoder mv_silk_encoder;  // opaque

// 标准 SILK_SDK 导出符号（不同微信版本可能大小写不同，逐个尝试）
static int (*mv_silk_Encode_Init)(mv_silk_encoder **) = NULL;
static int (*mv_silk_Encode)(mv_silk_encoder *, const mv_silk_enc_ctrl *,
                             const short *, int, unsigned char *, int *) = NULL;
static int (*mv_silk_Encode_destroy)(mv_silk_encoder *) = NULL;

static BOOL mv_silk_resolved = NO;

@implementation MyVoiceSILK

+ (instancetype)shared {
    static id s; static dispatch_once_t t; dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) [self resolve];
    return self;
}

- (void)resolve {
    if (mv_silk_resolved) return;
    mv_silk_resolved = YES;
    const char *inits[] = {"silk_Encode_Init", "Silk_Encode_Init", "SilkEncode_Init", NULL};
    const char *encs[]  = {"silk_Encode",      "Silk_Encode",      "SilkEncode",      NULL};
    void *h = RTLD_DEFAULT;
    for (int i = 0; inits[i]; i++) {
        mv_silk_Encode_Init = (int(*)(mv_silk_encoder**))dlsym(h, inits[i]);
        if (mv_silk_Encode_Init) { MVLog(@"[silk] 找到 init 符号: %s", inits[i]); break; }
    }
    for (int i = 0; encs[i]; i++) {
        mv_silk_Encode = (int(*)(mv_silk_encoder*,const mv_silk_enc_ctrl*,const short*,int,unsigned char*,int*))dlsym(h, encs[i]);
        if (mv_silk_Encode) { MVLog(@"[silk] 找到 encode 符号: %s", encs[i]); break; }
    }
    // destroy 可选
    mv_silk_Encode_destroy = (int(*)(mv_silk_encoder*))dlsym(h, "silk_Encode_destroy");
    if (!mv_silk_Encode_Init || !mv_silk_Encode)
        MVLog(@"[silk] 警告：未在本进程找到 SILK 符号，直发语音将失败（请用 frida 脚本确认微信 SILK 导出名）");
}

- (NSData*)encodePCM:(NSData*)pcm24k {
    if (!mv_silk_Encode_Init || !mv_silk_Encode) { [self resolve]; }
    if (!mv_silk_Encode_Init || !mv_silk_Encode) return nil;
    if (pcm24k.length < 2) return nil;

    mv_silk_encoder *enc = NULL;
    if (mv_silk_Encode_Init(&enc) != 0 || !enc) { MVLog(@"[silk] init 失败"); return nil; }

    mv_silk_enc_ctrl ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.API_sampleRate       = (int)MV_WECHAT_SR;   // 24000
    ctrl.maxInternalSampleRate= (int)MV_WECHAT_SR;
    ctrl.packetSize           = 480;                 // 20ms @ 24k = 480 samples（微信语音帧）
    ctrl.packetLossPercentage = 0;
    ctrl.useInBandFEC         = 0;
    ctrl.useDTX               = 0;
    ctrl.complexity           = 10;                  // 中档，质量/速度均衡
    ctrl.bitRate              = 0;                   // 0 = 自动（由复杂度与采样率决定）

    const short *samples = (const short*)pcm24k.bytes;
    int nTotal = (int)(pcm24k.length / 2);
    int frame = ctrl.packetSize;

    // SILK 输出缓冲：每帧上限约 250 字节
    NSMutableData *out = [NSMutableData dataWithCapacity:pcm24k.length/2];
    unsigned char payload[1024];
    int offset = 0;
    while (offset < nTotal) {
        int nIn = MIN(frame, nTotal - offset);
        int nBytes = 0;
        int ret = mv_silk_Encode(enc, &ctrl, samples + offset, nIn, payload, &nBytes);
        if (ret != 0 || nBytes <= 0) {
            MVLog(@"[silk] encode 帧失败 ret=%d nBytes=%d", ret, nBytes);
            break;
        }
        [out appendBytes:payload length:nBytes];
        offset += nIn;
    }
    if (mv_silk_Encode_destroy && enc) mv_silk_Encode_destroy(enc);
    MVLog(@"[silk] 编码完成 %lu samples → %lu bytes", (unsigned long)nTotal, (unsigned long)out.length);
    return out.length ? out : nil;
}

@end
