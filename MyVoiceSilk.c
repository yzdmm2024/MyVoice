// MyVoiceSilk.c — 微信/QQ .aud（SILK_V3）→ 标准 WAV（24kHz 单声道 16bit）
// ★ 2.8.10：内嵌腾讯 SILK 解码器（kn007/silk-v3-decoder，BSD 授权，见 silk/LICENSE）。
//   iOS 无系统 SILK 解码器，之前只能提示用户去电脑转码；现在本地直接解。
//
// 文件格式：[可选 1 字节版本前缀] + "#!SILK_V3"（或 "#!SILK_AMR2B"）+ 帧流。
// 每帧 = 2 字节 LE 长度 + 载荷；0xFFFF 结束（有的文件没有结束符，以数据读完为准）。

#include "MyVoiceSilk.h"
#include "SKP_Silk_SDK_API.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MV_SILK_API_RATE 24000   // 微信语音内部采样率即 24k，直接原速解出

int mv_silk_decode_file(const char *inPath, const char *outWavPath, double *outSeconds) {
    if (!inPath || !outWavPath) return -1;
    *outSeconds = 0;

    // 1) 读入整个文件
    FILE *in = fopen(inPath, "rb");
    if (!in) return -2;
    fseek(in, 0, SEEK_END);
    long fsize = ftell(in);
    fseek(in, 0, SEEK_SET);
    if (fsize < 16 || fsize > 32 * 1024 * 1024) { fclose(in); return -3; }   // 太小/太大都拒
    unsigned char *buf = (unsigned char *)malloc((size_t)fsize);
    if (!buf) { fclose(in); return -4; }
    if (fread(buf, 1, (size_t)fsize, in) != (size_t)fsize) { free(buf); fclose(in); return -5; }
    fclose(in);

    // 2) 定位 "#!SILK" 魔数（容忍微信的 0x02 前缀字节）
    unsigned char *p = (unsigned char *)memmem(buf, (size_t)fsize, "#!SILK", 6);
    if (!p) { free(buf); return -6; }
    long off = (long)(p - buf);
    if (off + 12 <= fsize && memcmp(p, "#!SILK_AMR2B", 12) == 0) off += 12;
    else if (off + 9 <= fsize && memcmp(p, "#!SILK_V3", 9) == 0) off += 9;
    else { free(buf); return -6; }

    // 3) 初始化解码器
    SKP_int32 decSize = 0;
    if (SKP_Silk_SDK_Get_Decoder_Size(&decSize) != 0) { free(buf); return -7; }
    void *decState = malloc((size_t)decSize);
    if (!decState) { free(buf); return -4; }
    if (SKP_Silk_SDK_InitDecoder(decState) != 0) { free(decState); free(buf); return -7; }

    // 4) 逐帧解码 → 追加 PCM
    size_t pcmCap = (size_t)fsize * 64 + 65536;      // SILK 压缩比通常 1:10~1:40
    SKP_int16 *pcm = (SKP_int16 *)malloc(pcmCap);
    SKP_int16 scratch[24000];                        // 单帧缓冲（100ms@24k绰绰有余）
    if (!pcm) { free(decState); free(buf); return -4; }
    size_t pcmFrames = 0;                            // 已解码样本数

    while (off + 2 <= fsize) {
        SKP_int32 frameSize = (SKP_int32)(buf[off] | (buf[off + 1] << 8));
        off += 2;
        if (frameSize == 0xFFFF) break;              // 流结束符
        if (off + frameSize > fsize) break;          // 截断帧（末尾静音被裁剪的微信语音常见）
        SKP_int32 outSamples = sizeof(scratch) / sizeof(scratch[0]);
        SKP_SILK_SDK_DecControlStruct ctrl;
        memset(&ctrl, 0, sizeof(ctrl));
        ctrl.API_sampleRate = MV_SILK_API_RATE;
        SKP_int ret = SKP_Silk_SDK_Decode(decState, &ctrl, 0,
                                          buf + off, frameSize,
                                          scratch, &outSamples);
        off += frameSize;
        if (ret != 0 || outSamples <= 0) continue;   // 坏帧跳过，不让整段报废
        if ((pcmFrames + (size_t)outSamples) * 2 > pcmCap) {
            size_t newCap = pcmCap * 2;
            SKP_int16 *np = (SKP_int16 *)realloc(pcm, newCap);
            if (!np) break;
            pcm = np; pcmCap = newCap;
        }
        memcpy(pcm + pcmFrames, scratch, (size_t)outSamples * sizeof(SKP_int16));
        pcmFrames += (size_t)outSamples;
    }
    free(decState);
    free(buf);

    if (pcmFrames < (size_t)(MV_SILK_API_RATE * 2)) { free(pcm); return -8; }  // <2 秒基本没内容
    size_t pcmBytes = pcmFrames * sizeof(SKP_int16);

    // 5) 写 WAV（24kHz 单声道 16bit）
    FILE *outf = fopen(outWavPath, "wb");
    if (!outf) { free(pcm); return -9; }
    unsigned char hdr[44];
    memcpy(hdr + 0, "RIFF", 4); hdr[4] = (unsigned char)((36 + pcmBytes) & 0xFF); hdr[5] = (unsigned char)(((36 + pcmBytes) >> 8) & 0xFF); hdr[6] = (unsigned char)(((36 + pcmBytes) >> 16) & 0xFF); hdr[7] = (unsigned char)(((36 + pcmBytes) >> 24) & 0xFF);
    memcpy(hdr + 8, "WAVE", 4);
    memcpy(hdr + 12, "fmt ", 4); hdr[16] = 16; hdr[17] = hdr[18] = hdr[19] = 0;
    hdr[20] = 1; hdr[21] = 0;            // PCM
    hdr[22] = 1; hdr[23] = 0;            // 单声道
    hdr[24] = (unsigned char)(MV_SILK_API_RATE & 0xFF); hdr[25] = (unsigned char)((MV_SILK_API_RATE >> 8) & 0xFF); hdr[26] = hdr[27] = 0;
    SKP_int32 byteRate = MV_SILK_API_RATE * 2;
    hdr[28] = (unsigned char)(byteRate & 0xFF); hdr[29] = (unsigned char)((byteRate >> 8) & 0xFF); hdr[30] = (unsigned char)((byteRate >> 16) & 0xFF); hdr[31] = (unsigned char)((byteRate >> 24) & 0xFF);
    hdr[32] = 2; hdr[33] = 0;            // 块对齐
    hdr[34] = 16; hdr[35] = 0;           // 位宽
    memcpy(hdr + 36, "data", 4); hdr[40] = (unsigned char)(pcmBytes & 0xFF); hdr[41] = (unsigned char)((pcmBytes >> 8) & 0xFF); hdr[42] = (unsigned char)((pcmBytes >> 16) & 0xFF); hdr[43] = (unsigned char)((pcmBytes >> 24) & 0xFF);
    if (fwrite(hdr, 1, 44, outf) != 44 || fwrite(pcm, 1, pcmBytes, outf) != pcmBytes) {
        fclose(outf); free(pcm); return -10;
    }
    fclose(outf);
    *outSeconds = (double)pcmFrames / MV_SILK_API_RATE;
    free(pcm);
    return 0;
}
