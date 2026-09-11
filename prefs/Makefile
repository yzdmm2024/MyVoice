TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := MyVoicePrefs
MyVoicePrefs_FILES := MyVoicePreferences.m
MyVoicePrefs_INSTALL_PATH := /Library/PreferenceLoader/Preferences
MyVoicePrefs_PRIVATE_FRAMEWORKS := Preferences
MyVoicePrefs_FRAMEWORKS := Foundation UIKit
MyVoicePrefs_CFLAGS := -fobjc-arc -Wno-error
MyVoicePrefs_PRINCIPAL_CLASS = MyVoicePrefsListController
MyVoicePrefs_INFOPLIST_FILE = Info.plist
MyVoicePrefs_RESOURCE_FILES = MyVoicePrefs.plist

include $(THEOS_MAKE_PATH)/bundle.mk
