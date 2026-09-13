// MyVoiceSilk.h — 微信/QQ .aud（SILK_V3）本地解码为 WAV
// ★ 2.8.10：iOS 无系统 SILK 解码器，内嵌腾讯 SILK 解码器（见 silk/LICENSE）。

#ifndef MyVoiceSilk_h
#define MyVoiceSilk_h

#include <stddef.h>

// 解码成功返回 0，outSeconds 输出音频秒数；失败返回负数错误码。
int mv_silk_decode_file(const char *inPath, const char *outWavPath, double *outSeconds);

#endif /* MyVoiceSilk_h */
