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
