#import "MyVoiceCloud.h"
#import "MyVoiceCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonCrypto.h>

// ---- HTTP 辅助 ----
static NSError* MVErr(NSString *msg) {
    return [NSError errorWithDomain:@"MyVoiceCloud" code:-1 userInfo:@{NSLocalizedDescriptionKey:msg}];
}

@implementation MyVoiceCloud

+ (instancetype)shared {
    static id s; static dispatch_once_t t; dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

+ (double)sampleRate { return MV_WECHAT_SR; }

#pragma mark - 端点

- (NSString*)maasHost {
    NSString *ws = MVWorkspace();
    if (!ws.length) return nil;
    return [NSString stringWithFormat:@"https://%@.cn-beijing.maas.aliyuncs.com/api/v1", ws];
}

#pragma mark - TTS（合成）

- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    NSString *apiKey = MVAPIKey();
    NSString *host = [self maasHost];
    NSString *model = MVCurrentModel();
    if (!apiKey.length) { completion(nil, MVErr(@"未配置 DashScope API Key（设置→我的语音）")); return; }
    if (!host)          { completion(nil, MVErr(@"未配置 DashScope 业务空间 ID（设置→我的语音→workspace）")); return; }
    if (!voiceID.length){ completion(nil, MVErr(@"未选择音色：请先在设置里克隆/选择一个音色")); return; }
    if (!text.length)  { completion(nil, MVErr(@"文字为空")); return; }

    NSString *url = [host stringByAppendingString:@"/services/audio/tts/SpeechSynthesizer"];
    NSDictionary *body = @{
        @"model": model,
        @"input": @{
            @"text": text,
            @"voice": voiceID,
            @"format": @"wav",
            @"sample_rate": @24000
        }
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = json;
    req.timeoutInterval = 60;

    MVLog(@"[cloud] TTS 请求 model=%@ voice=%@ textLen=%lu", model, voiceID, (unsigned long)text.length);
    NSURLSession *s = [NSURLSession sharedSession];
    [[s dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (e) { MVLog(@"[cloud] TTS 网络错误 %@", e); completion(nil, e); return; }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (code != 200) {
            NSString *msg = [[NSString alloc] initWithData:d?:[NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[cloud] TTS HTTP %ld body=%@", (long)code, msg);
            completion(nil, MVErr([NSString stringWithFormat:@"TTS 失败 HTTP %ld：%@", (long)code, msg]));
            return;
        }
        // 解析 audio_url（非流式返回 URL，24h 有效）
        NSError *je = nil;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&je];
        NSString *audioURL = nil;
        if ([j[@"output"] isKindOfClass:[NSDictionary class]]) audioURL = j[@"output"][@"audio_url"];
        if (!audioURL.length) audioURL = j[@"audio_url"];
        if (!audioURL.length) {
            MVLog(@"[cloud] TTS 未返回 audio_url：%@", j);
            completion(nil, MVErr(@"TTS 未返回音频 URL"));
            return;
        }
        // 二次下载 wav
        [[s dataTaskWithURL:[NSURL URLWithString:audioURL] completionHandler:^(NSData *wd, NSURLResponse *wr, NSError *we){
            if (we || wd.length == 0) { MVLog(@"[cloud] 下载音频失败 %@", we); completion(nil, we ?: MVErr(@"下载音频为空")); return; }
            NSData *pcm = [self pcmFromWavData:wd];
            if (!pcm) { completion(nil, MVErr(@"音频解码失败（非 wav？）")); return; }
            MVLog(@"[cloud] TTS 解码完成 %lu bytes PCM", (unsigned long)pcm.length);
            completion(pcm, nil);
        }] resume];
    }] resume];
}

// wav 数据 → 24kHz 单声道 S16 PCM
- (NSData*)pcmFromWavData:(NSData*)wav {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"mv_%@.wav", [[NSUUID UUID] UUIDString]]];
    if (![wav writeToFile:tmp atomically:NO]) return nil;
    NSError *e = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:tmp] error:&e];
    if (!file) { MVLog(@"[cloud] AVAudioFile 失败 %@", e); return nil; }

    AVAudioFormat *outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                              sampleRate:MV_WECHAT_SR
                                                               channels:1
                                                            interleaved:NO];
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:file.processingFormat toFormat:outFmt];
    NSMutableData *pcm = [NSMutableData data];
    while (1) {
        AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                               frameCapacity:4096];
        AVAudioConverterInputStatus st = 0;
        BOOL ok = [file readIntoBuffer:inBuf error:&e];
        if (!ok || inBuf.frameLength == 0) break;
        AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt
                                                                frameCapacity:inBuf.frameLength];
        NSError *cerr = nil;
        [conv convertToBuffer:outBuf error:&cerr withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount npackets, AVAudioConverterInputStatus *status){
            *status = AVAudioConverterInputStatus_HaveData;
            return inBuf;
        }];
        if (outBuf.frameLength > 0) {
            int16_t *ch = outBuf.int16ChannelData[0];
            [pcm appendBytes:ch length:outBuf.frameLength * 2];
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    MVLog(@"[cloud] wav→pcm %lu bytes (@24k)", (unsigned long)pcm.length);
    return pcm.length ? pcm : nil;
}

#pragma mark - OSS 上传（克隆音色用，一次性拿公网 URL）

- (void)uploadToOSS:(NSData*)data objectKey:(NSString*)key contentType:(NSString*)ct completion:(void(^)(NSString* url, NSError*))completion {
    NSString *bucket = MVOSSBucket(), *host = MVOSSHost(), *ak = MVOSSAk(), *sk = MVOSSSk();
    if (!bucket.length || !host.length || !ak.length || !sk.length) {
        completion(nil, MVErr(@"未配置 OSS（设置→我的语音→OSS）")); return;
    }
    NSString *date = [self rfc1123];
    NSString *stringToSign = [NSString stringWithFormat:@"PUT\n\n%@\n%@\n/%@/%@",
                              ct ?: @"audio/wav", date, bucket, key];
    NSString *sig = [self hmacSHA1:sk string:stringToSign];
    NSString *auth = [NSString stringWithFormat:@"OSS %@:%@", ak, sig];
    NSString *url = [NSString stringWithFormat:@"https://%@.%@/%@", bucket, host, key];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"PUT";
    [req setValue:date forHTTPHeaderField:@"Date"];
    [req setValue:ct ?: @"audio/wav" forHTTPHeaderField:@"Content-Type"];
    [req setValue:auth forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = data;
    req.timeoutInterval = 60;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (e || code/100 != 2) {
            MVLog(@"[oss] 上传失败 %ld %@", (long)code, e);
            completion(nil, e ?: MVErr([NSString stringWithFormat:@"OSS 上传失败 %ld", (long)code]));
        } else {
            MVLog(@"[oss] 上传成功 %@", url);
            completion(url, nil);
        }
    }] resume];
}

- (NSString*)rfc1123 {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    f.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
    return [f stringFromDate:[NSDate date]];
}

- (NSString*)hmacSHA1:(NSString*)key string:(NSString*)str {
    NSData *k = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSData *m = [str dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char out[CC_SHA1_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA1, k.bytes, k.length, m.bytes, m.length, out);
    return [[NSData dataWithBytes:out length:CC_SHA1_DIGEST_LENGTH] base64EncodedStringWithOptions:0];
}

#pragma mark - 声音复刻（克隆）

- (void)cloneVoiceWithName:(NSString*)name referenceAudioPath:(NSString*)path completion:(void(^)(NSString*,NSError*))completion {
    NSString *apiKey = MVAPIKey();
    NSString *host = [self maasHost];
    if (!apiKey.length) { completion(nil, MVErr(@"未配置 DashScope API Key")); return; }
    if (!host)          { completion(nil, MVErr(@"未配置 workspace")); return; }
    NSData *audio = [NSData dataWithContentsOfFile:path];
    if (audio.length == 0) { completion(nil, MVErr(@"参考音频读取失败")); return; }

    NSString *key = [NSString stringWithFormat:@"myvoice/%@_%@.wav",
                     name.length ? name : @"ref", [[NSUUID UUID] UUIDString]];
    [self uploadToOSS:audio objectKey:key contentType:@"audio/wav" completion:^(NSString *url, NSError *e){
        if (!url) { completion(nil, e ?: MVErr(@"OSS 上传失败")); return; }
        // customization 端点
        NSString *cu = [host stringByAppendingString:@"/services/audio/tts/customization"];
        NSDictionary *body = @{
            @"model": @"voice-enrollment",
            @"input": @{
                @"action": @"create_voice",
                @"target_model": MVCurrentModel(),
                @"prefix": @"myvoice",
                @"url": url
            }
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:cu]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = json;
        req.timeoutInterval = 60;
        MVLog(@"[cloud] 克隆请求 url=%@", url);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *err){
            if (err) { completion(nil, err); return; }
            NSInteger code = [(NSHTTPURLResponse*)r statusCode];
            if (code != 200) {
                NSString *msg = [[NSString alloc] initWithData:d?:[NSData data] encoding:NSUTF8StringEncoding];
                MVLog(@"[cloud] 克隆 HTTP %ld %@", (long)code, msg);
                completion(nil, MVErr([NSString stringWithFormat:@"克隆失败 %ld：%@", (long)code, msg]));
                return;
            }
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSString *vid = nil;
            if ([j[@"output"] isKindOfClass:[NSDictionary class]]) vid = j[@"output"][@"voice_id"];
            if (!vid.length) vid = j[@"voice_id"];
            if (!vid.length) { MVLog(@"[cloud] 克隆未返回 voice_id %@", j); completion(nil, MVErr(@"克隆未返回 voice_id")); return; }
            MVLog(@"[cloud] 克隆成功 voice_id=%@", vid);
            completion(vid, nil);
        }] resume];
    }];
}

@end
