TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := MyVoicePrefs
MyVoicePrefs_FILES := MyVoicePreferences.m
# 标准布局：bundle 装到 /Library/PreferenceBundles，入口 plist 装到
# /Library/PreferenceLoader/Preferences（见下方 internal-stage）。
MyVoicePrefs_INSTALL_PATH := /Library/PreferenceBundles
MyVoicePrefs_FRAMEWORKS := Foundation UIKit
MyVoicePrefs_PRIVATE_FRAMEWORKS := Preferences
MyVoicePrefs_CFLAGS := -fobjc-arc -Wno-error
# Resources/ 目录存在时 theos 会自动作为 bundle 资源目录（含 Info.plist / Root.plist）

include $(THEOS_MAKE_PATH)/bundle.mk

# 注册「设置 → 我的语音」入口。
# 注意：写 $(THEOS_STAGING_DIR)/Library/... 即可，打包时 theos 会自动补 /var/jb 前缀。
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/MyVoicePrefs.plist$(ECHO_END)
