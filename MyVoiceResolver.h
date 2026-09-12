#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 版本自适应：微信私有类名/方法名/ivar 随版本变化，这里用候选清单 + 运行时探测，
// 命中任意一个即可，未命中再回落。避免原版"硬编码一挂全挂"的问题。
@interface MyVoiceResolver : NSObject
+ (Class)classWithCandidates:(NSArray<NSString*>*)names;
+ (SEL)selectorWithCandidates:(Class)cls names:(NSArray<NSString*>*)sels;
+ (id)valueForIvars:(id)obj names:(NSArray<NSString*>*)ivars;

// 候选清单（来自 TTSFloat_v29 逆向 + 通用微信类名）
+ (NSArray<NSString*>*)chatVCCandidates;
+ (NSArray<NSString*>*)talkerIvarCandidates;
+ (NSArray<NSString*>*)recordStartCandidates;
+ (NSArray<NSString*>*)recordEndCandidates;
+ (NSArray<NSString*>*)sendVoiceCandidates;
+ (NSArray<NSString*>*)audioSenderCandidates;

// 当前聊天对象 wxid（多路径解析，见 .m 里的优先级注释）
+ (NSString*)currentTalker;
+ (UIViewController*)topViewController;
// 遍历当前所有可见 VC（含子/模态），用于定位聊天页与「按住说话」按钮
+ (NSArray<UIViewController*>*)allViewControllers;
// 判定某个 VC 是不是聊天页（类名含 MsgContent）
+ (BOOL)isChatVC:(id)vc;
// 自己的 wxid（构造语音消息的 m_nsFromUsr；带缓存 + 落共享配置）
+ (NSString*)selfWxid;
// 微信自己发消息时 AddMsg:MsgWrap: 用的第一个参数（hook 捕获，直发复用；可能为 nil）
+ (id)capturedAddMsgArg0;
// 供 hook 调用：抓下 AddMsg:MsgWrap: 的第一个参数
+ (void)captureAddMsgArg0:(id)arg0;
// 取一个可用窗口（多 scene 兼容）。⚠️ 必须在主线程调用。
+ (UIWindow*)anyWindow;

// 从一个「聊天 VC」上解析会话 wxid（微信 8.0.75 实测：getChatUserName / GetContact /
// m_contact / m_delegate.m_contact / 当前会话消息 五条路）
+ (NSString*)talkerFromChatVC:(id)vc;
// 供 hook 调用：解析并记住（进程内缓存 + 落盘）
+ (void)captureFromChatVC:(id)vc;
// 上次捕获到的会话（进程内 → 落盘）
+ (NSString*)capturedTalker;
+ (NSString*)sanitize:(NSString*)s;

// 调试：dump 当前聊天 VC 类名与联系人相关字段，用于精修微信版本符号
+ (NSString*)debugChatInfo;
// 给面板显示的一行状态：当前走了哪条路 / 识别到谁
+ (NSString*)talkerDiag;
@end
