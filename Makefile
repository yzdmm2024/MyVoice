# 我的语音 (MyVoice) — rootless theos tweak
# 离线系统 TTS，纯功能，无赞赏/打赏。
ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := MyVoice
MyVoice_FILES := Tweak.x MyVoiceManager.m MyVoiceResolver.m MyVoiceEngine.m \
                 MyVoiceAVSEngine.m MyVoicePanel.m MyVoiceSender.m \
                 MyVoiceCloud.m MyVoiceSILK.m MyVoiceCloneController.m
MyVoice_FRAMEWORKS := Foundation UIKit AVFoundation Security
MyVoice_CFLAGS := -fobjc-arc -Wno-error -Wno-deprecated-declarations

# 离线 TTS 引擎：本地 Flite（由 flite/vendor.sh 交叉编译，CI 中拉取并构建）。
# 若 flite/build/libflite.a 存在则启用真实离线合成；否则回退为内置 Sine 占位，保证必定可编译。
ifneq ($(wildcard flite/build/libflite.a),)
  MyVoice_CFLAGS += -DMV_HAS_FLITE
  MyVoice_FILES += MyVoiceFlite.m
  MyVoice_LDFLAGS += -Lflite/build
  MyVoice_LDFLAGS += -lflite -lflite_cmu_us_kal -lflite_cmulex -lflite_usenglish
endif

include $(THEOS_MAKE_PATH)/tweak.mk

# 同时产出可直接 TrollFools 注入的 dylib 成品
after-build::
	@mkdir -p .theos/artifacts
	@cp .theos/obj/MyVoice.dylib .theos/artifacts/MyVoice.dylib 2>/dev/null || true
	@echo "[MyVoice] 构建完成：deb 走 Sileo，dylib 位于 .theos/artifacts/MyVoice.dylib 可直接 TrollFools 注入"

# 设置面板作为子工程
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/subproject.mk
