#import <UIKit/UIKit.h>

// 2.8.17 真机抓包诊断：仅打印，绝不改任何发送行为。
// 全部输出带 [mvdiag] 前缀，方便 idevicesyslog | grep mvdiag 抓取。

BOOL mvDiagIsQQ(void);
BOOL mvDiagIsDouyin(void);
// ★ 2.8.35：触摸诊断开关（默认关）。以前 UIApplication -sendEvent: 里的诊断代码
//   对**每次触摸**都跑，命中就写日志文件 —— 这是白耗电。现在由它统一把关。
BOOL mvDiagTapLogEnabled(void);

void mvDiagDumpClasses(void);
void MVDebugDumpInputTree(UIView *root);
NSString *mvDiagGRInfo(UIGestureRecognizer *gr);
