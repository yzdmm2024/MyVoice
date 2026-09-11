#import <Preferences/Preferences.h>

@interface MyVoicePrefsListController : PSListController
@end

@implementation MyVoicePrefsListController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"MyVoicePrefs" target:self];
    }
    return _specifiers;
}

@end
