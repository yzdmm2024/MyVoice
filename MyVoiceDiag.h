#import <UIKit/UIKit.h>

// 2.8.17 真机抓包诊断：仅打印，绝不改任何发送行为。
// 全部输出带 [mvdiag] 前缀，方便 idevicesyslog | grep mvdiag 抓取。

BOOL mvDiagIsQQ(void);
void mvDiagDumpClasses(void);
void MVDebugDumpInputTree(UIView *root);
NSString *mvDiagGRInfo(UIGestureRecognizer *gr);
