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

// 当前聊天对象 wxid（遍历 VC 树取 talker ivar）
+ (NSString*)currentTalker;
+ (UIViewController*)topViewController;
@end
