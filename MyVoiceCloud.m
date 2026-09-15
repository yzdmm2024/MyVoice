#import "MyVoiceCloud.h"
#import "MyVoiceCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonCrypto.h>

@interface MyVoiceCloud ()
@property (nonatomic, copy) NSString *lastDouyinText;   // ★ 2.8.24：面板最近准备发送的文本
@property (nonatomic, copy) NSString *lastDouyinVoice;  // ★ 2.8.24：面板最近准备发送的音色
@end

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
    // 留空 = 默认业务空间：走公开 DashScope 域名，只需 API Key，无需 Workspace ID。
    // 只有当用户填了「子业务空间」的 ID 时，才切到 MAAS 专属子域。
    NSString *ws = MVWorkspace();
    if (!ws.length) return @"https://dashscope.aliyuncs.com/api/v1";
    return [NSString stringWithFormat:@"https://%@.cn-beijing.maas.aliyuncs.com/api/v1", ws];
}

#pragma mark - 连通性自检

// 只发一个空 body 的 POST：鉴权（Key 有效性）在参数校验之前执行，所以
//   200/400 → Key 有效（400 只是参数不全）
//   401     → Key 无效；403 → 未开通/地域或业务空间不对
// 这样既能真正验证 Key，又不消耗额度、不产生任何侧效应。
- (void)testAPIKeyWithCompletion:(void(^)(BOOL, NSString*))completion {
    void (^fin)(BOOL, NSString*) = ^(BOOL ok, NSString *m){
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, m); });
    };
    NSString *apiKey = MVAPIKey();
    if (!apiKey.length) {
        fin(NO, @"未配置 API Key（设置 → 我的语音）。");
        return;
    }
    NSString *host = [self maasHost];
    NSString *url = [host stringByAppendingString:@"/services/audio/tts/customization"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 20;
    MVLog(@"[cloud] 自检 POST %@", url);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (e) {
            MVLog(@"[cloud] 自检网络错误 %@", e);
            fin(NO, [NSString stringWithFormat:@"网络错误：%@\n（检查手机能否上网／是否开了代理、VPN）",
                     e.localizedDescription]);
            return;
        }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        NSString *body = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
        if (body.length > 240) body = [[body substringToIndex:240] stringByAppendingString:@"…"];
        MVLog(@"[cloud] 自检 HTTP %ld %@", (long)code, body);

        if (code == 200 || code == 400) {
            fin(YES, @"API Key 有效，接口可以正常访问。\n（自检请求是故意发不完整的，400 属正常）");
        } else if (code == 401) {
            fin(NO, @"API Key 无效（401）。请确认 sk- 后面没漏字符，或重新创建一个。");
        } else if (code == 403) {
            fin(NO, [NSString stringWithFormat:
                @"被拒绝（403）。常见原因：① 百炼没开通；② 控制台地域不是「华北2 北京」；"
                @"③ 用了子业务空间但 workspace 没填。\n%@", body]);
        } else {
            fin(NO, [NSString stringWithFormat:@"返回意外状态 %ld：\n%@", (long)code, body]);
        }
    }] resume];
}

#pragma mark - ★ 2.2.7 合成缓存（消除「点发送后还要等合成」那段延迟）

// 真机实测：一次 11 字的合成，从发出请求到拿到 PCM 用掉 0.89s
// （DNS + TLS 握手 + 服务端生成 + 下载 wav + 解码）。
// 这段耗时完全发生在"用户已经点了发送"之后，是纯等待。
// 做法：把 PCM 按【服务商|模型|音色|语气|语速|文字】缓存起来，
//   面板里文字一改就在后台预合成 → 用户点「发送」时直接命中，合成耗时归零。
// 注意：说话人/语速/语气任一变化都会换 key，绝不会串音色。
static NSMutableDictionary *gMVTTSCache = nil;      // key -> NSData(16k 单声道 PCM)
static NSMutableArray      *gMVTTSCacheKeys = nil;   // 简易 LRU 顺序（末尾最新）

static NSString* MVTTSCacheKey(NSString *text, NSString *voiceID) {
    if (!text.length) return nil;
    if (MVTTSProvider() == 1) {
        // ★ 2.8.7：key 里放真正会发出去的 instructions（旧版放的是无效的 emotion/speed，
        //   改了风格会命中旧音频 —— 又是一次"调了没用"）。
        return [NSString stringWithFormat:@"q|%@|%@|%@|%.2f|%@",
                MVQwenModel(), (voiceID.length ? voiceID : MVQwenVoice()),
                MVQwenInstructions() ?: @"", MVQwenSpeed(), text];
    }
    // ★ 2.8.5：key 必须带上全部表现参数。
    //   旧版只含 model|voiceID|text —— 改了风格/语速/音高仍然命中旧音频，
    //   表现就是"调了没用"（跟语速滑块对克隆无效是同一类坑）。
    return [NSString stringWithFormat:@"c|%@|%@|%ld|%.2f|%.2f|%ld|%@|%@",
            MVCurrentModel(), (voiceID.length ? voiceID : @""),
            (long)MVCosyStyle(), MVCosyRate(), MVCosyPitch(), (long)MVCosyVolume(),
            MVCosyInstruction() ?: @"", text];
}

static NSData* MVTTSCacheGet(NSString *key) {
    if (!key.length) return nil;
    @synchronized(@"mv-tts-cache") {
        NSData *d = gMVTTSCache[key];
        if (d.length) { [gMVTTSCacheKeys removeObject:key]; [gMVTTSCacheKeys addObject:key]; }
        return d;
    }
}

static void MVTTSCachePut(NSString *key, NSData *pcm) {
    if (!key.length || !pcm.length) return;
    @synchronized(@"mv-tts-cache") {
        if (!gMVTTSCache) { gMVTTSCache = [NSMutableDictionary dictionary]; gMVTTSCacheKeys = [NSMutableArray array]; }
        gMVTTSCache[key] = pcm;
        [gMVTTSCacheKeys removeObject:key];
        [gMVTTSCacheKeys addObject:key];
        while (gMVTTSCacheKeys.count > 6) {          // 每条几十~几百 KB，只留最近 6 条
            NSString *old = gMVTTSCacheKeys.firstObject;
            [gMVTTSCacheKeys removeObjectAtIndex:0];
            [gMVTTSCache removeObjectForKey:old];
        }
    }
}

+ (void)clearSynthesisCache {
    @synchronized(@"mv-tts-cache") {
        [gMVTTSCache removeAllObjects];
        [gMVTTSCacheKeys removeAllObjects];
    }
    MVLog(@"[cache] 合成缓存已清空");
}

// ★ 2.8.7：缓存统计（面板「缓存管理」显示 条数 / 占用）
+ (NSDictionary*)cacheStats {
    @synchronized(@"mv-tts-cache") {
        NSUInteger bytes = 0;
        for (NSData *d in gMVTTSCache.allValues) bytes += d.length;
        return @{ @"count": @(gMVTTSCache.count), @"bytes": @(bytes) };
    }
}

#pragma mark - TTS（合成）

- (void)synthesizeText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    if (!completion) return;

    // ① 命中预合成缓存 → 零网络、零等待
    NSString *key = MVTTSCacheKey(text, voiceID);
    NSData *hit = MVTTSCacheGet(key);
    if (hit.length) {
        MVLog(@"[cache] ✅ 命中预合成缓存（%lu 字节 ≈ %.2fs）→ 合成耗时归零",
              (unsigned long)hit.length, hit.length / 32000.0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ completion(hit, nil); });
        return;
    }

    // ② 未命中 → 真实请求；成功后顺手入缓存（同一条文字再发就是秒发）
    void (^wrap)(NSData*, NSError*) = ^(NSData *pcm, NSError *e){
        if (pcm.length && !e) MVTTSCachePut(key, pcm);
        completion(pcm, e);
    };
    // ★ 2.8.32：分流必须按【模型家族】，不能按 provider。
    //   官方文档（模型与端点必须匹配，否则 400「url error, please check url!」）：
    //     · Qwen-TTS  qwen3-tts-flash / qwen3-tts-instruct-flash
    //       → https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation
    //     · Qwen-Audio-TTS qwen-audio-3.0-tts-plus / -flash，与 CosyVoice cosyvoice-*
    //       → {业务空间}.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer
    //   旧版按 provider 分流：千问克隆音色(myvoice-*，复刻时绑定 target_model=qwen-audio-3.0-tts-plus)
    //   被送进了 Qwen-TTS 专用端点 → 服务端必然返回 url error → 面板显示「千问合成失败/模型名不支持」。
    //   这条报错跟充没充值、有没有额度毫无关系，换模型档位也没用（克隆音色锁定自己的模型）。
    NSString *routeModel = MVModelForVoice(voiceID);
    if (!routeModel.length) routeModel = (MVTTSProvider() == 1) ? MVQwenModel() : MVCosyModel();
    BOOL audioFamily = [routeModel hasPrefix:@"qwen-audio-3.0-tts"] || [routeModel hasPrefix:@"cosyvoice"];
    MVLog(@"[route] voiceID=%@ → model=%@ → %@ 通道%@", voiceID.length ? voiceID : @"(默认)",
          routeModel, audioFamily ? @"audio/tts(SpeechSynthesizer)" : @"multimodal-generation",
          (MVSelfHostEnabled() && audioFamily) ? @"（自建服务器）" : @"");
    // ★ 2.8.35：通道互斥的**最后一道闸**。
    //   选了「自建·免费」通道时，千问族（qwen3-tts-* / qwen-audio-3.0-tts-*）一律不放行 ——
    //   否则用户以为在免费跑，实际每句都在扣额度，而且从界面/日志上都看不出来。
    if (MVChannel() == 0 && !audioFamily) {
        MVLog(@"[route] ⛔ 自建通道拦截千问族模型 %@（不允许跨通道消耗额度）", routeModel);
        completion(nil, MVErr(@"当前是「自建服务器（免费）」通道，不会调用千问云端。\n\n"
                              @"· 想听这个千问音色：设置 → 我的语音 → 发音通道 切到「云端千问」\n"
                              @"· 想继续免费：在音色列表里选「我的克隆」或 CosyVoice 预置音色"));
        return;
    }
    // ★ 2.8.35：通道互斥的**最后一道闸**。
    //   选了「自建·免费」通道时，千问族（qwen3-tts-* / qwen-audio-3.0-tts-*）一律不放行 ——
    //   否则用户以为在免费跑，实际每句都在扣额度，而且从界面/日志上都看不出来。
    if (MVChannel() == 0 && !audioFamily) {
        MVLog(@"[route] ⛔ 自建通道拦截千问族模型 %@（不允许跨通道消耗额度）", routeModel);
        completion(nil, MVErr(@"当前是「自建服务器（免费）」通道，不会调用千问云端。\n\n"
                              @"· 想听这个千问音色：设置 → 我的语音 → 发音通道 切到「云端千问」\n"
                              @"· 想继续免费：在音色列表里选「我的克隆」或 CosyVoice 预置音色"));
        return;
    }
    if (audioFamily) {
        // ★ 2.8.33：自建服务器开启时，CosyVoice 族（克隆 / 预置）全部走本地 server.py，免额度
        if (MVSelfHostEnabled()) {
            [self synthesizeSelfHostText:text voiceID:voiceID completion:wrap];
            return;
        }
        [self synthesizeCosyText:text voiceID:voiceID completion:wrap];
        return;
    }
    [self synthesizeQwenText:text voiceID:voiceID completion:wrap];
}

#pragma mark - ★ 2.2.7 预合成 / 连接预热

- (void)prewarmText:(NSString*)text voiceID:(NSString*)voiceID {
    // ★ 2.8.24：留存「最近准备发送」的文本/音色，供抖音半自动直发取用。
    if (text.length) self.lastDouyinText = text;
    if (voiceID.length) self.lastDouyinVoice = voiceID;
    if (!text.length || text.length > 300) return;
    if (MVEngineMode() != 1) return;                       // 离线引擎不吃网络，预合成没意义
    if (!MVAPIKey().length)  return;                        // 没配 Key：交给发送路径去明确报错
    if (MVVoiceProvider(voiceID) == 0 && !(voiceID.length ? voiceID : MVCurrentVoiceID()).length) return;
    if (MVTTSCacheGet(MVTTSCacheKey(text, voiceID)).length) return;   // 已经缓存过

    MVLog(@"[prewarm] 后台预合成 %lu 字…（不影响发送，只为点「发送」时零等待）",
          (unsigned long)text.length);
    [self synthesizeText:text voiceID:voiceID completion:^(NSData *pcm, NSError *err){
        if (pcm.length) MVLog(@"[prewarm] ✅ 预合成就绪（%lu 字节 ≈ %.2fs）",
                              (unsigned long)pcm.length, pcm.length / 32000.0);
        else            MVLog(@"[prewarm] 预合成未成功（不影响正常发送）：%@",
                              err.localizedDescription ?: @"未知");
    }];
}

// ★ 2.8.24：抖音半自动直发取用——面板「最近准备发送」的文本/音色。
- (NSString*)lastComposedText  { return self.lastDouyinText ?: @""; }
- (NSString*)lastComposedVoice { return self.lastDouyinVoice ?: @""; }

// 只建立 TCP+TLS，不做真实合成（用"参数不完整"的旧接口：鉴权在参数校验前执行 → 400，
// 不消耗额度、无副作用，但连接与 DNS 已经热了）。
- (void)prewarmConnection {
    NSString *apiKey = MVAPIKey();
    if (!apiKey.length) return;
    static NSTimeInterval lastAt = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastAt < 300) return;                        // 5 分钟内只暖一次
    lastAt = now;

    // ★ 必须与真正合成用的 host 一致，否则连接复用不起来
    NSString *host = (MVTTSProvider() == 1) ? @"https://dashscope.aliyuncs.com/api/v1" : [self maasHost];
    NSString *url = [host stringByAppendingString:@"/services/audio/tts/customization"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 10;
    NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        MVLog(@"[prewarm] 连接预热完成 %ldms（%@）—— 之后的合成省掉握手",
              (long)(([[NSDate date] timeIntervalSince1970] - t0) * 1000),
              e ? e.localizedDescription
                : [NSString stringWithFormat:@"HTTP %ld", (long)[(NSHTTPURLResponse*)r statusCode]]);
    }] resume];
}

// 千问 Qwen-TTS（预置音色，无需克隆）：
//   POST /api/v1/services/aigc/multimodal-generation/generation
//   body: { model, input: { text, voice, language_type } }
//   非流式响应: output.audio.url（24h 有效 wav），部分版本会直接给 output.audio.data（Base64）。
//   注意该端点只在公共 dashscope 域名上提供，MAAS 子业务空间域名不适用。
- (void)synthesizeQwenText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    NSString *apiKey = MVAPIKey();
    if (!apiKey.length) { completion(nil, MVErr(@"未配置 DashScope API Key（设置→我的语音）")); return; }
    if (!text.length)   { completion(nil, MVErr(@"文字为空")); return; }
    NSString *voice = voiceID.length ? voiceID : MVQwenVoice();
    // ★ 2.8.30：克隆音色必须用它自己复刻时绑定的 target_model（voice_id 与 target_model 强绑定，
    //   合成时模型不一致会失败、或退化回普通话），不能写死 MVQwenModel()。
    // ★ 2.8.32：但【预置音色】反过来必须听用户在面板选的「千问模型」档位 ——
    //   旧版一律取音色列表里写死的 qwen3-tts-flash，用户点了「可调版」也被覆盖掉，
    //   于是 instructions（风格 / 语速）永远不生效，表现就是"调了没反应"。
    NSString *model = MVIsQwenPresetVoice(voiceID) ? MVQwenModel() : MVModelForVoice(voiceID);
    if (!model.length) model = MVQwenModel();
    // ★ 2.8.32 安全网：Qwen-Audio-TTS 族不在本端点上（详见 MVFriendlyAPIError 里 url error 的说明）。
    //   万一走到这里（典型是克隆音色），立刻转正确通道，绝不发出一个必然 400 的请求。
    if ([model hasPrefix:@"qwen-audio-3.0-tts"]) {
        MVLog(@"[qwen] 模型 %@ 属 Qwen-Audio-TTS 族 → 转 audio/tts(SpeechSynthesizer) 通道", model);
        [self synthesizeCosyText:text voiceID:(voiceID.length ? voiceID : voice) completion:completion];
        return;
    }
    NSString *url = @"https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation";
    NSMutableDictionary *input = [NSMutableDictionary dictionaryWithDictionary:@{
        @"text": text,
        @"voice": voice,
        @"language_type": @"Auto"
    }];
    // ★ 2.8.7：删掉 input.emotion / input.speed —— 这两个【不是本接口的合法字段】，
    //   服务端静默忽略。这就是用户反馈"语速调了没反应、语气段控更没反应"的真因。
    //   千问的调节只能走 instructions，且仅 qwen3-tts-instruct-flash 系列认这个参数。
    NSString *inst = MVQwenInstructions();
    if (inst.length) {
        if (MVQwenSupportsInstructions(model)) {
            input[@"instructions"] = inst;
            input[@"optimize_instructions"] = @YES;   // 让服务端再润色一遍，表现力更好
            MVLog(@"[qwen] instructions=%@", inst);
        } else {
            MVLog(@"[qwen] ⚠️ 模型 %@ 不支持 instructions —— 风格/语速不会生效。"
                  @"在面板「千问模型」里切到 qwen3-tts-instruct-flash（可调版）即可。", model);
        }
    }

    NSDictionary *body = @{
        @"model": model,
        @"input": input
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = json;
    req.timeoutInterval = 60;

    MVLog(@"[qwen] TTS 请求 model=%@ voice=%@ textLen=%lu", model, voice, (unsigned long)text.length);
    NSTimeInterval tReq = [[NSDate date] timeIntervalSince1970];      // ★ 2.2.7 耗时打点
    NSURLSession *s = [NSURLSession sharedSession];
    [[s dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (e) { MVLog(@"[qwen] TTS 网络错误 %@", e); completion(nil, e); return; }
        MVLog(@"[perf] 合成网络 %ldms（DNS + TLS + 服务端生成 + 下载）",
              (long)(([[NSDate date] timeIntervalSince1970] - tReq) * 1000));
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (code != 200) {
            NSString *msg = [[NSString alloc] initWithData:d?:[NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[qwen] TTS HTTP %ld body=%@", (long)code, msg);
            completion(nil, MVErr(MVFriendlyAPIError(code, msg, [NSString stringWithFormat:@"千问合成失败(模型 %@)", model])));
            return;
        }
        NSError *je = nil;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&je];
        NSDictionary *audio = nil;
        if ([j[@"output"] isKindOfClass:[NSDictionary class]] &&
            [j[@"output"][@"audio"] isKindOfClass:[NSDictionary class]]) audio = j[@"output"][@"audio"];

        // 优先用内联 Base64（省一次下载），没有再走 URL
        NSString *b64 = audio[@"data"];
        NSData *wav = nil;
        if ([b64 isKindOfClass:[NSString class]] && b64.length > 100) {
            wav = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        }
        if (!wav.length) {
            NSString *audioURL = audio[@"url"];
            if (!audioURL.length) {
                MVLog(@"[qwen] TTS 未返回音频：%@", j);
                completion(nil, MVErr(@"千问没有返回音频。多数是音色与模型不匹配，或该模型未开通：\n"
                    @"标准版(qwen3-tts-flash)与可调版(qwen3-tts-instruct-flash)支持的音色可能不同，\n"
                    @"换一个音色、或在面板「千问模型」里切一个版本再试。"));
                return;
            }
            // 二次下载 wav
            [[s dataTaskWithURL:[NSURL URLWithString:audioURL] completionHandler:^(NSData *wd, NSURLResponse *wr, NSError *we){
                if (we || wd.length == 0) { MVLog(@"[qwen] 下载音频失败 %@", we); completion(nil, we ?: MVErr(@"下载音频为空")); return; }
                [self finishQwenWav:wd completion:completion];
            }] resume];
            return;
        }
        [self finishQwenWav:wav completion:completion];
    }] resume];
}

- (void)finishQwenWav:(NSData*)wav completion:(void(^)(NSData*,NSError*))completion {
    NSTimeInterval tDec = [[NSDate date] timeIntervalSince1970];
    NSData *pcm = [self pcmFromWavData:wav];
    if (!pcm) { completion(nil, MVErr(@"音频解码失败（非 wav？）")); return; }
    MVLog(@"[perf] 解码 %ldms（wav %lu → 16k 单声道 %lu 字节 ≈ %.2fs）",
          (long)(([[NSDate date] timeIntervalSince1970] - tDec) * 1000),
          (unsigned long)wav.length, (unsigned long)pcm.length, pcm.length / 32000.0);
    MVLog(@"[qwen] TTS 解码完成 %lu bytes PCM", (unsigned long)pcm.length);
    completion(pcm, nil);
}

// CosyVoice（克隆/设计音色）
- (void)synthesizeCosyText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    NSString *apiKey = MVAPIKey();
    NSString *host = [self maasHost];
    // ★ 2.8.4：合成模型必须与「这个 voiceID 复刻时绑定的 target_model」一致，
    //   不能拿"当前选中音色"的 model 去套（两者可能不是同一个音色）→ 按 voiceID 反查。
    NSString *model = MVModelForVoice(voiceID);
    if (!apiKey.length) { completion(nil, MVErr(@"未配置 DashScope API Key（设置→我的语音）")); return; }
    if (!voiceID.length){ completion(nil, MVErr(@"未选择音色：请先在设置里克隆/选择一个音色")); return; }
    if (!text.length)  { completion(nil, MVErr(@"文字为空")); return; }

    NSString *url = [host stringByAppendingString:@"/services/audio/tts/SpeechSynthesizer"];
    // ★ 2.4.3：format/sample_rate 属于 parameters（PC 端 200 实测格式）；
    //   放在 input 里部分网关会忽略，且响应字段也不是当初以为的 audio_url。
    // ★ 2.8.5：补齐官方支持、但旧版一直没传的表现参数 —— 这组参数直接决定"像不像真人"。
    //   不传 = 模型默认朗读腔（字正腔圆、每字等长、句尾一律降调）= 浓烈 AI 味。
    //   instruction 仅在 v3.5-flash / v3.5-plus / v3-flash 上可用，其它模型传了会 400，故先判断。
    double rate   = MVCosyRate();
    double pitch  = MVCosyPitch();
    NSInteger vol = MVCosyVolume();
    NSString *inst = MVCosyInstruction();
    BOOL instOK = (inst.length > 0) && MVCosySupportsInstruction(model);

    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"format"] = @"wav";
    params[@"sample_rate"] = @16000;
    params[@"language_hints"] = @[@"zh"];              // 数字/英文/符号按中文读法
    if (fabs(rate - 1.0)  > 0.001) params[@"rate"]  = @(rate);
    if (fabs(pitch - 1.0) > 0.001) params[@"pitch"] = @(pitch);
    if (vol != 50)                 params[@"volume"] = @(vol);
    if (instOK)                    params[@"instruction"] = inst;

    // 兼容两版文档：新版把 format/sample_rate 放在 input 里，老网关认 parameters。
    // 两处都写，服务端取其一，多余的键会被忽略（不会 400）。
    NSMutableDictionary *input = [NSMutableDictionary dictionaryWithDictionary:@{
        @"text": text,
        @"voice": voiceID,
        @"format": @"wav",
        @"sample_rate": @16000
    }];
    if (fabs(rate - 1.0)  > 0.001) input[@"rate"]  = @(rate);
    if (fabs(pitch - 1.0) > 0.001) input[@"pitch"] = @(pitch);
    if (vol != 50)                 input[@"volume"] = @(vol);
    if (instOK)                    input[@"instruction"] = inst;

    NSDictionary *body = @{
        @"model": model,
        @"input": input,
        @"parameters": params
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = json;
    req.timeoutInterval = 60;

    MVLog(@"[cloud] TTS 请求 model=%@ voice=%@ textLen=%lu rate=%.2f pitch=%.2f vol=%ld inst=%@",
          model, voiceID, (unsigned long)text.length, rate, pitch, (long)vol,
          instOK ? inst : @"（未启用）");
    NSURLSession *s = [NSURLSession sharedSession];
    [[s dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (e) { MVLog(@"[cloud] TTS 网络错误 %@", e); completion(nil, e); return; }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (code != 200) {
            NSString *msg = [[NSString alloc] initWithData:d?:[NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[cloud] TTS HTTP %ld body=%@", (long)code, msg);
            completion(nil, MVErr(MVFriendlyAPIError(code, msg, [NSString stringWithFormat:@"语音合成失败(模型 %@)", model])));
            return;
        }
        // ★ 2.4.3：真机抓包确认响应结构是 output.audio.url（http 链接，24h 有效），
        //   另有 output.audio.data（Base64，一般同时给 URL 时为空）。旧版找的
        //   output.audio_url 这个字段根本不存在 → 永远报「未返回音频 URL」。
        NSError *je = nil;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&je];
        NSDictionary *outDict = [j[@"output"] isKindOfClass:[NSDictionary class]] ? j[@"output"] : nil;
        NSDictionary *audio = [outDict[@"audio"] isKindOfClass:[NSDictionary class]] ? outDict[@"audio"] : nil;
        NSString *audioURL = [audio[@"url"] isKindOfClass:[NSString class]] ? audio[@"url"] : nil;
        NSString *b64Data = [audio[@"data"] isKindOfClass:[NSString class]] ? audio[@"data"] : nil;
        // 兼容旧字段名
        if (!audioURL.length) audioURL = outDict[@"audio_url"] ?: j[@"audio_url"];

        if (!audioURL.length && b64Data.length > 100) {
            NSData *wd = [[NSData alloc] initWithBase64EncodedString:b64Data options:0];
            NSData *pcm = [self pcmFromWavData:wd];
            if (!pcm) { completion(nil, MVErr(@"音频解码失败（Base64）")); return; }
            MVLog(@"[cloud] TTS（Base64）解码完成 %lu bytes PCM", (unsigned long)pcm.length);
            completion(pcm, nil);
            return;
        }
        if (!audioURL.length) {
            MVLog(@"[cloud] TTS 未返回音频：%@", j);
            completion(nil, MVErr(@"TTS 未返回音频（响应里既无 URL 也无 Base64，多为音色无效或未开通模型）"));
            return;
        }
        // OSS 结果站支持 https，强制升级避免 ATS 拦 http
        audioURL = [audioURL stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
        MVLog(@"[cloud] TTS 返回音频 URL：%@", audioURL);
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


// ★ 2.8.33：自建服务器合成（本地 CosyVoice / server.py，免费克隆音色）
//   请求 POST {selfHostURL}/tts，body: {text, voice, speed?, instruction?, ref_audio_b64?, ref_text?}
//   服务器返回原始 wav 字节（与 DashScope 响应同构），复用 pcmFromWavData 解码成 16k 单声道。
- (void)synthesizeSelfHostText:(NSString*)text voiceID:(NSString*)voiceID completion:(void(^)(NSData*,NSError*))completion {
    if (!text.length) { completion(nil, MVErr(@"文字为空")); return; }
    if (!voiceID.length) { completion(nil, MVErr(@"未选择音色")); return; }
    NSString *base = MVSelfHostURL();
    NSString *url = [base stringByAppendingString:@"/tts"];

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"text"]  = text;
    payload[@"voice"] = voiceID;
    payload[@"speed"] = @(MVCosyRate());

    if ([voiceID hasPrefix:@"myvoice"]) {
        // 克隆音色：带参考音频（零样本复刻）
        NSData *ref = MVSelfHostRefAudioForVoice(voiceID);
        if (ref.length) {
            payload[@"ref_audio_b64"] = [ref base64EncodedStringWithOptions:0];
            NSString *rt = MVGetStr([NSString stringWithFormat:@"refText_%@", voiceID]);
            if (rt.length) payload[@"ref_text"] = rt;
            MVLog(@"[selfhost] 克隆音色 %@ 带参考音频 %lu 字节", voiceID, (unsigned long)ref.length);
        } else {
            MVLog(@"[selfhost] ⚠️ 克隆音色 %@ 缺少本地参考音频（请在该模式下重新复刻一次）", voiceID);
            completion(nil, MVErr([NSString stringWithFormat:
                @"自建服务器：克隆音色「%@」缺少本地参考音频。\\n请在建服模式下重新点「＋音色管理」复刻，参考音频会自动存本机。", voiceID]));
            return;
        }
    } else {
        // 预置 CosyVoice 音色：可带 instruction
        NSString *inst = MVCosyInstruction();
        if (inst.length) payload[@"instruction"] = inst;
    }

    NSError *je = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&je];
    if (!json) { completion(nil, MVErr(@"请求构造失败")); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSString *tok = MVSelfHostToken();
    if (tok.length) [req setValue:tok forHTTPHeaderField:@"X-Token"];
    req.HTTPBody = json;
    req.timeoutInterval = 120;     // 本地 CPU 推理每句 3~10s，给足余量

    // ★ 2.8.35：日志脱密 —— 公网地址不进日志文件
    MVLog(@"[selfhost] TTS 请求 %@ voice=%@ len=%lu",
          MVMaskHost(url), voiceID, (unsigned long)text.length);
    NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (e) { MVLog(@"[selfhost] 网络错误 %@", e); completion(nil, e); return; }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (code != 200) {
            NSString *msg = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[selfhost] HTTP %ld %@", (long)code, msg);
            completion(nil, MVErr([NSString stringWithFormat:
                @"自建服务器返回 %ld：%@（确认 server.py 已启动 / ECS 中转已通 / 地址正确）",
                (long)code, msg.length ? msg : @"未知错误"]));
            return;
        }
        MVLog(@"[perf] 自建合成网络 %ldms", (long)(([[NSDate date] timeIntervalSince1970] - t0) * 1000));
        NSData *pcm = [self pcmFromWavData:d];
        if (!pcm) { completion(nil, MVErr(@"自建服务器返回的音频解码失败（非 wav？）")); return; }
        MVLog(@"[selfhost] TTS 解码完成 %lu bytes PCM", (unsigned long)pcm.length);
        completion(pcm, nil);
    }] resume];
}

// ★ 2.8.37：同步自建服务器音色库（GET {selfHostURL}/voicebank）。
//   把电脑上 server.py 的 voices/<名字> 与模型预置音色拉到手机，存进共享域 selfHostVoices；
//   面板 voiceList 会合并它们，选中即免上传参考音频直接用（合成发 voice=<id>，服务端自己读 ref.wav）。
- (void)syncServerVoicesWithCompletion:(void(^)(NSInteger count, NSError* err))completion {
    if (!completion) return;
    if (!MVSelfHostEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(0, MVErr(@"未开启「自建服务器」通道（设置 → 我的语音 → 发音通道 → 自建·免费）"));
        });
        return;
    }
    NSString *url = [MVSelfHostURL() stringByAppendingString:@"/voicebank"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    NSString *tok = MVSelfHostToken();
    if (tok.length) [req setValue:tok forHTTPHeaderField:@"X-Token"];
    req.timeoutInterval = 20;
    MVLog(@"[selfhost] 同步音色库 %@", MVMaskHost(url));
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (e) {
            MVLog(@"[selfhost] 同步网络错误 %@", e);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, e); });
            return;
        }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (code != 200) {
            NSString *msg = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[selfhost] 同步 HTTP %ld %@", (long)code, msg);
            NSError *err = MVErr([NSString stringWithFormat:
                @"自建服务器返回 %ld：%@（确认 server.py 已启动 / ECS 中转已通 / 地址正确）",
                (long)code, msg.length ? msg : @"未知错误"]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, err); });
            return;
        }
        NSError *je = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:&je];
        if (!json || ![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, MVErr(@"音色库数据解析失败（非 JSON？）")); });
            return;
        }
        NSMutableArray *out = [NSMutableArray array];
        NSArray *presets = [json[@"presets"] isKindOfClass:[NSArray class]] ? json[@"presets"] : @[];
        for (NSDictionary *p in presets) {
            NSString *pid = [p[@"id"] isKindOfClass:[NSString class]] ? p[@"id"] : nil;
            if (!pid.length) continue;
            [out addObject:@{
                @"name":     [p[@"label"] isKindOfClass:[NSString class]] ? p[@"label"] : pid,
                @"voiceID":  pid,
                @"provider": @0,
                @"serverVoice": @YES,
                @"model":    @"cosyvoice-v3.5-plus",
                @"type":     @"preset"}];
        }
        NSArray *clones = [json[@"clones"] isKindOfClass:[NSArray class]] ? json[@"clones"] : @[];
        for (NSDictionary *c in clones) {
            NSString *cid = [c[@"id"] isKindOfClass:[NSString class]] ? c[@"id"] : nil;
            if (!cid.length) continue;
            [out addObject:@{
                @"name":     [c[@"label"] isKindOfClass:[NSString class]] ? c[@"label"] : cid,
                @"voiceID":  cid,
                @"provider": @0,
                @"serverVoice": @YES,
                @"model":    @"cosyvoice-v3.5-plus",
                @"type":     @"clone",
                @"has_ref":  c[@"has_ref"] ?: @NO,
                @"ref_text": [c[@"ref_text"] isKindOfClass:[NSString class]] ? c[@"ref_text"] : @""}];
        }
        MVSetServerVoices(out);
        MVLog(@"[selfhost] 同步到 %lu 个服务器音色", (unsigned long)out.count);
        dispatch_async(dispatch_get_main_queue(), ^{ completion((NSInteger)out.count, nil); });
    }] resume];
}

// ---- RIFF 小工具 ----
static inline uint16_t MVrd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t MVrd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// wav → **16kHz 单声道 S16** PCM（确定性实现，不依赖 AVAudioConverter）
//
// 为什么换掉 AVAudioConverter（2.2.6）：
//   旧实现用 convertToBuffer:error:withInputFromBlock:，而那个 block 无论被调用几次
//   都返回同一个 inBuf 并标 HaveData。转换器在一次 convert 调用里若需要多于一个输入块
//   （降采样时非常常见），就会**把同一段输入再消费一遍** → 输出里插进重复帧。
//   听感正是用户反馈的"一卡一卡 / 有两个声音"。
//   现在自己解析 RIFF 头拿到真实采样率/声道/位深，自己降混 + 自己线性重采样，
//   全流程确定、可核对（日志会打印真实格式），并保证输出恒为 16kHz 单声道。
- (NSData*)pcmFromWavData:(NSData*)wav {
    if (wav.length < 44) { MVLog(@"[wav] 数据太短 %lu 字节", (unsigned long)wav.length); return nil; }
    const uint8_t *b = (const uint8_t*)wav.bytes;

    if (memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0) {
        // 不是 RIFF/WAVE（个别版本可能直接吐裸 PCM）：按 DashScope 常见的
        // 24kHz 单声道 S16 兜底处理，至少保证音调/时长正确。
        MVLog(@"[wav] 非 RIFF/WAVE 头，按 24kHz 单声道 S16 兜底（%lu 字节）", (unsigned long)wav.length);
        NSData *o = MVResampleS16Mono(wav, 24000.0, MV_WECHAT_SR);
        MVLog(@"[wav] → 16kHz %lu 字节 ≈ %.2fs", (unsigned long)o.length, o.length / 32000.0);
        return o.length ? o : nil;
    }

    uint16_t tag = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    const uint8_t *dat = NULL; NSUInteger datLen = 0;
    NSUInteger off = 12;
    while (off + 8 <= wav.length) {
        const uint8_t *cid = b + off;
        uint32_t csz = MVrd32(b + off + 4);
        NSUInteger body = off + 8;
        if (csz > (uint32_t)(wav.length - body)) csz = (uint32_t)(wav.length - body);
        if (memcmp(cid, "fmt ", 4) == 0 && csz >= 16) {
            tag  = MVrd16(b + body);
            ch   = MVrd16(b + body + 2);
            rate = MVrd32(b + body + 4);
            bits = MVrd16(b + body + 14);
            // WAVE_FORMAT_EXTENSIBLE：真实格式在 SubFormat 的头 2 字节
            if (tag == 0xFFFE && csz >= 26) tag = MVrd16(b + body + 24);
        } else if (memcmp(cid, "data", 4) == 0) {
            dat = b + body; datLen = csz;
        }
        off = body + csz + (csz & 1);   // 块按偶数字节对齐
    }
    MVLog(@"[wav] 真实格式：tag=%u %uch %uHz %ubit data=%lu字节",
          tag, ch, rate, bits, (unsigned long)datLen);
    if (!dat || !datLen) { MVLog(@"[wav] 未找到 data 块"); return nil; }
    if (bits != 16 || tag != 1) {
        MVLog(@"[wav] 非 16bit PCM，转 AVAudioFile 兜底");
        return [self pcmFromWavViaAVF:wav];
    }
    if (ch < 1 || ch > 2) { MVLog(@"[wav] 声道数异常 %u", ch); return nil; }

    NSData *mono = nil;
    if (ch == 1) {
        mono = [NSData dataWithBytes:dat length:datLen];
    } else {
        NSUInteger n = datLen / 4;                 // 交错 LRLR
        NSMutableData *m = [NSMutableData dataWithLength:n * 2];
        if (!m) return nil;
        const short *i16 = (const short*)dat;
        short *o = (short*)m.mutableBytes;
        for (NSUInteger i = 0; i < n; i++)
            o[i] = (short)(((int)i16[i * 2] + (int)i16[i * 2 + 1]) / 2);
        mono = m;
    }
    if (!mono.length) return nil;

    double srcRate = rate ? (double)rate : 24000.0;
    NSData *out = MVResampleS16Mono(mono, srcRate, MV_WECHAT_SR);
    if (!out.length) { MVLog(@"[wav] 重采样无输出"); return nil; }
    MVLog(@"[wav] ✅ %uHz %uch → 16kHz 单声道 %lu 字节 ≈ %.2fs",
          rate, ch, (unsigned long)out.length, out.length / 32000.0);
    return out;
}

// 兜底：非 16bit PCM 的 wav 用 AVAudioFile 解。
// ★ 关键修正：输入 block 对同一块 buffer 只能供给一次 —— 重复返回正是"重复帧/一卡一卡"的根因。
- (NSData*)pcmFromWavViaAVF:(NSData*)wav {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"mv_%@.wav", [[NSUUID UUID] UUIDString]]];
    if (![wav writeToFile:tmp atomically:NO]) return nil;
    NSError *e = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:tmp] error:&e];
    if (!file) { MVLog(@"[wav] AVAudioFile 打开失败 %@", e); return nil; }
    double srcRate = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : 24000.0;
    AVAudioFormat *outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                             sampleRate:MV_WECHAT_SR
                                                              channels:1
                                                           interleaved:NO];
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:file.processingFormat toFormat:outFmt];
    NSMutableData *pcm = [NSMutableData data];
    while (1) {
        AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                               frameCapacity:4096];
        BOOL ok = [file readIntoBuffer:inBuf error:&e];
        if (!ok || inBuf.frameLength == 0) break;
        AVAudioFrameCount cap = (AVAudioFrameCount)((double)inBuf.frameLength * MV_WECHAT_SR / srcRate + 64);
        AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:cap];
        __block BOOL served = NO;
        NSError *cerr = nil;
        [conv convertToBuffer:outBuf error:&cerr
           withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount np, AVAudioConverterInputStatus *st){
            if (served) { *st = AVAudioConverterInputStatus_NoDataNow; return nil; }
            served = YES; *st = AVAudioConverterInputStatus_HaveData; return inBuf;
        }];
        if (outBuf.frameLength > 0 && outBuf.int16ChannelData)
            [pcm appendBytes:outBuf.int16ChannelData[0] length:outBuf.frameLength * 2];
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    MVLog(@"[wav] AVF 兜底 → 16kHz %lu 字节 ≈ %.2fs",
          (unsigned long)pcm.length, pcm.length / 32000.0);
    return pcm.length ? pcm : nil;
}

#pragma mark - DashScope 临时托管（★ 2.4.0：录音复刻免 OSS）

// DashScope 官方临时文件托管，两步：
//   ① GET /api/v1/uploads?action=getPolicy&model=voice-enrollment → 拿一次性上传凭证
//   ② multipart 直传到凭证里的 OSS host → 文件以 oss://{key} 引用
// 复刻接口配 X-DashScope-OssResourceResolve: enable 头即可直接吃 oss:// 地址。
// PC 端真账号实测：上传 200，create_voice 返回 voice_id —— 录音复刻从此
// 【只需 API Key，不需要用户配置任何 OSS】。凭证 5 分钟过期，量小够用。
- (void)uploadToDashScopeInstant:(NSData*)data fileName:(NSString*)fname
                     contentType:(NSString*)ct
                      completion:(void(^)(NSString *ossURL, NSError *err))completion {
    NSString *apiKey = MVAPIKey();
    if (!apiKey.length) { completion(nil, MVErr(@"未配置 API Key")); return; }
    if (!fname.length) fname = @"ref.wav";

    NSString *pu = @"https://dashscope.aliyuncs.com/api/v1/uploads?action=getPolicy&model=voice-enrollment";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pu]];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 30;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        if (e) { completion(nil, e); return; }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d ?: [NSData data] options:0 error:nil];
        NSDictionary *pol = [j[@"data"] isKindOfClass:[NSDictionary class]] ? j[@"data"] : nil;
        if (code != 200 || !pol || ![pol[@"policy"] isKindOfClass:[NSString class]]) {
            NSString *msg = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[instant] getPolicy 失败 %ld %@", (long)code, msg);
            completion(nil, MVErr([NSString stringWithFormat:@"临时托管凭证获取失败 %ld：%@", (long)code, msg]));
            return;
        }
        NSString *host = pol[@"upload_host"];
        NSString *key  = [NSString stringWithFormat:@"%@/%@", pol[@"upload_dir"], fname];
        NSString *boundary = @"mv-instant-boundary-7A3F5C";
        NSMutableData *body = [NSMutableData data];
        void (^field)(NSString*, NSString*) = ^(NSString *n, NSString *v){
            [body appendData:[[NSString stringWithFormat:
                @"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
                boundary, n, v] dataUsingEncoding:NSUTF8StringEncoding]];
        };
        field(@"policy",                 pol[@"policy"]);
        field(@"Signature",              pol[@"signature"]);
        field(@"key",                    key);
        field(@"OSSAccessKeyId",         pol[@"oss_access_key_id"]);
        field(@"success_action_status",  @"200");
        field(@"x-oss-object-acl",       [pol[@"x_oss_object_acl"] isKindOfClass:[NSString class]] ? pol[@"x_oss_object_acl"] : @"private");
        field(@"x-oss-forbid-overwrite", [pol[@"x_oss_forbid_overwrite"] isKindOfClass:[NSString class]] ? pol[@"x_oss_forbid_overwrite"] : @"true");
        if ([pol[@"x_oss_server_side_encryption"] isKindOfClass:[NSString class]])
            field(@"x-oss-server-side-encryption", pol[@"x_oss_server_side_encryption"]);
        [body appendData:[[NSString stringWithFormat:
            @"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n",
            boundary, fname, ct ?: @"audio/wav"] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:data];
        [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

        NSMutableURLRequest *up = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:host]];
        up.HTTPMethod = @"POST";
        up.HTTPBody = body;
        up.timeoutInterval = 120;
        [up setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
            forHTTPHeaderField:@"Content-Type"];
        MVLog(@"[instant] 直传 %lu 字节 → oss://%@", (unsigned long)data.length, key);
        [[[NSURLSession sharedSession] dataTaskWithRequest:up completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2){
            NSInteger c2 = [(NSHTTPURLResponse*)r2 statusCode];
            if (e2 || c2 != 200) {
                NSString *msg = [[NSString alloc] initWithData:d2 ?: [NSData data] encoding:NSUTF8StringEncoding];
                MVLog(@"[instant] 直传失败 %ld %@ %@", (long)c2, msg, e2);
                completion(nil, e2 ?: MVErr([NSString stringWithFormat:@"音频托管失败 %ld %@", (long)c2, msg]));
                return;
            }
            MVLog(@"[instant] ✅ 直传成功 oss://%@", key);
            completion([NSString stringWithFormat:@"oss://%@", key], nil);
        }] resume];
    }] resume];
}

// 复刻注册（create_voice）：音频地址可以是公网 http(s)（用户自有 OSS）或 oss://（临时托管）
- (void)enrollCreateVoiceWithURL:(NSString*)audioURL
                         model:(NSString*)enrollModel
                         resolve:(BOOL)resolve
                      completion:(void(^)(NSString *voiceID, NSError *err))completion {
    NSString *apiKey = MVAPIKey();
    NSString *host = [self maasHost];
    NSString *cu = [host stringByAppendingString:@"/services/audio/tts/customization"];
    // ★ 2.8.6：补齐官方 voice-enrollment 的三个质量参数（旧版一个都没传）。
    //   language_hints  帮模型对准语种，音色特征提得更准；
    //   max_prompt_audio_length 决定拿多少秒音频做声纹（默认 10s，本插件默认 20s）；
    //   enable_preprocess 降噪/增强（安静干声关掉更还原）。这三项只对部分模型生效，
    //   所以按模型判断后再带，避免给 cosyvoice-v3-plus / v2 传了直接 400。
    NSMutableDictionary *in = [NSMutableDictionary dictionary];
    in[@"action"]       = @"create_voice";
    in[@"target_model"] = enrollModel.length ? enrollModel : MVCosyModel();
    in[@"prefix"]       = @"myvoice";
    in[@"url"]          = audioURL;
    in[@"language_hints"] = @[@"zh"];
    if (MVCloneSupportsQuality(MVCosyModel())) {
        in[@"max_prompt_audio_length"] = @(MVCloneMaxLen());
        in[@"enable_preprocess"]       = MVClonePreprocess() ? @YES : @NO;
    }
    NSDictionary *body = @{
        @"model": @"voice-enrollment",
        @"input": in
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:cu]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    if (resolve) [req setValue:@"enable" forHTTPHeaderField:@"X-DashScope-OssResourceResolve"];
    req.HTTPBody = json;
    req.timeoutInterval = 60;
    MVLog(@"[cloud] 复刻请求 url=%@ resolve=%d target_model=%@ maxLen=%.0fs preprocess=%d",
          audioURL, resolve, enrollModel, MVCloneMaxLen(), (int)MVClonePreprocess());
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *err){
        if (err) { completion(nil, err); return; }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (code != 200) {
            NSString *msg = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[cloud] 复刻 HTTP %ld %@", (long)code, msg);
            completion(nil, MVErr(MVFriendlyAPIError(code, msg, @"克隆失败")));
            return;
        }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSString *vid = nil;
        if ([j[@"output"] isKindOfClass:[NSDictionary class]]) vid = j[@"output"][@"voice_id"];
        if (!vid.length) vid = j[@"voice_id"];
        if (!vid.length) { MVLog(@"[cloud] 复刻未返回 voice_id %@", j); completion(nil, MVErr(@"复刻未返回 voice_id")); return; }
        MVLog(@"[cloud] ✅ 复刻成功 voice_id=%@", vid);
        completion(vid, nil);
    }] resume];
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


#pragma mark - 复刻回退（cosyvoice 不开通时试 qwen-audio）

- (void)mvEnrollWithFallback:(NSString*)audioURL model:(NSString*)firstModel resolve:(BOOL)resolve completion:(void(^)(NSString *voiceID, NSString *model, NSError *err))completion {
    [self enrollCreateVoiceWithURL:audioURL model:firstModel resolve:resolve completion:^(NSString *vid, NSError *e){
        if (vid.length) { completion(vid, firstModel, nil); return; }
        // ★ 2.8.30：首模型(cosyvoice-v3.5-plus)失败 → 回退 qwen-audio-3.0-tts-plus。
        //   很多 DashScope 账号只开了千问 TTS、没开 CosyVoice 权限，克隆会直接报错"无法克隆"。
        NSString *fb = @"qwen-audio-3.0-tts-plus";
        if ([firstModel isEqualToString:fb]) { completion(nil, nil, e); return; }
        MVLog(@"[cloud] 复刻首模型 %@ 失败，回退 %@", firstModel, fb);
        [self enrollCreateVoiceWithURL:audioURL model:fb resolve:resolve completion:^(NSString *vid2, NSError *e2){
            if (vid2.length) completion(vid2, fb, nil); else completion(nil, nil, e2 ?: e);
        }];
    }];
}

#pragma mark - 声音复刻（克隆）

- (void)cloneVoiceWithName:(NSString*)name referenceAudioPath:(NSString*)path completion:(void(^)(NSString *voiceID, NSString *model, NSError *err))completion {
    // ★ 2.8.33：自建服务器模式 —— 完全不连 DashScope，参考音频存本机，本地 server.py 零样本复刻
    if (MVSelfHostEnabled()) {
        NSData *audio = [NSData dataWithContentsOfFile:path];
        if (audio.length == 0) { completion(nil, nil, MVErr(@"参考音频读取失败")); return; }
        NSString *vid = [NSString stringWithFormat:@"myvoice-%@",
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
        MVSelfHostSaveRefAudio(vid, audio);
        MVLog(@"[clone] 自建模式：参考音频已存本机(%lu 字节)，voiceID=%@",
              (unsigned long)audio.length, vid);
        completion(vid, @"cosyvoice-v3.5-plus", nil);
        return;
    }
    NSString *apiKey = MVAPIKey();
    if (!apiKey.length) { completion(nil, nil, MVErr(@"未配置 DashScope API Key")); return; }
    NSData *audio = [NSData dataWithContentsOfFile:path];
    if (audio.length == 0) { completion(nil, nil, MVErr(@"参考音频读取失败")); return; }

    // ★ 2.4.0 三态：配了自有 OSS → 老路径（公网 URL）；没配 → DashScope 临时托管（免 OSS）
    BOOL hasOSS = (MVOSSBucket().length && MVOSSHost().length && MVOSSAk().length && MVOSSSk().length);
    if (hasOSS) {
        NSString *ext2 = path.pathExtension.length ? path.pathExtension.lowercaseString : @"wav";
        NSString *key = [NSString stringWithFormat:@"myvoice/%@_%@.%@",
                         name.length ? name : @"ref", [[NSUUID UUID] UUIDString], ext2];
        NSDictionary *ctMap2 = @{@"wav": @"audio/wav", @"mp3": @"audio/mpeg", @"m4a": @"audio/mp4",
                                 @"aac": @"audio/aac", @"flac": @"audio/flac", @"amr": @"audio/amr"};
        [self uploadToOSS:audio objectKey:key contentType:(ctMap2[ext2] ?: @"audio/wav") completion:^(NSString *url, NSError *e){
            if (!url) { completion(nil, nil, e ?: MVErr(@"OSS 上传失败")); return; }
            [self mvEnrollWithFallback:url model:MVCosyModel() resolve:NO completion:completion];
        }];
        return;
    }

    MVLog(@"[clone] 未配置 OSS，改走 DashScope 临时托管（免 OSS 复刻）");
    // ★ 2.4.2：上传音频复刻支持 wav/mp3/m4a/aac 等，按扩展名给文件名与 Content-Type
    NSString *ext = path.pathExtension.length ? path.pathExtension.lowercaseString : @"wav";
    NSDictionary *ctMap = @{@"wav": @"audio/wav", @"mp3": @"audio/mpeg", @"m4a": @"audio/mp4",
                            @"aac": @"audio/aac", @"flac": @"audio/flac", @"amr": @"audio/amr"};
    NSString *ct = ctMap[ext] ?: @"audio/wav";
    NSString *fname = [NSString stringWithFormat:@"mv_%@.%@", [[NSUUID UUID] UUIDString], ext];
    [self uploadToDashScopeInstant:audio fileName:fname contentType:ct completion:^(NSString *ossURL, NSError *e){
        if (!ossURL) { completion(nil, nil, e ?: MVErr(@"音频托管失败")); return; }
        [self mvEnrollWithFallback:ossURL model:MVCosyModel() resolve:YES completion:completion];
    }];
}

#pragma mark - 声音设计（文字描述 → 音色，无 OSS / 无录音）

- (void)designVoiceWithName:(NSString*)name
                     prompt:(NSString*)prompt
                previewText:(NSString*)previewText
                 completion:(void(^)(NSString*, NSError*))completion {
    NSString *apiKey = MVAPIKey();
    NSString *host = [self maasHost];
    if (!apiKey.length) { completion(nil, MVErr(@"未配置 DashScope API Key（设置→我的语音）")); return; }
    if (!prompt.length) { completion(nil, MVErr(@"音色描述为空")); return; }

    NSString *model = MVDesignModel();
    NSString *cu = [host stringByAppendingString:@"/services/audio/tts/customization"];
    NSDictionary *body = @{
        @"model": @"voice-enrollment",
        @"input": @{
            @"action": @"create_voice",
            @"target_model": model,
            @"voice_prompt": prompt,
            @"preview_text": previewText.length ? previewText : @"你好，这是用我的新音色说的话。",
            @"prefix": @"myvoice"
        },
        @"parameters": @{ @"sample_rate": @16000, @"response_format": @"wav" }
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:cu]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = json;
    req.timeoutInterval = 120;
    MVLog(@"[cloud] 声音设计请求 model=%@ prompt=%@", model, prompt);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *err){
        if (err) { completion(nil, err); return; }
        NSInteger code = [(NSHTTPURLResponse*)r statusCode];
        if (code != 200) {
            NSString *msg = [[NSString alloc] initWithData:d?:[NSData data] encoding:NSUTF8StringEncoding];
            MVLog(@"[cloud] 声音设计 HTTP %ld %@", (long)code, msg);
            completion(nil, MVErr([NSString stringWithFormat:@"生成失败 %ld：%@", (long)code, msg]));
            return;
        }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSString *vid = nil;
        if ([j[@"output"] isKindOfClass:[NSDictionary class]]) vid = j[@"output"][@"voice_id"];
        if (!vid.length) vid = j[@"voice_id"];
        if (!vid.length) { MVLog(@"[cloud] 声音设计未返回 voice_id %@", j); completion(nil, MVErr(@"未返回 voice_id")); return; }
        MVLog(@"[cloud] 声音设计成功 voice_id=%@", vid);
        completion(vid, nil);
    }] resume];
}

@end
