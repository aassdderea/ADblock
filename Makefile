TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AdBlock
AdBlock_FILES = Tweak.m

# ← 关键修复：添加编译标志
AdBlock_CFLAGS = -fobjc-arc \
    -Wno-deprecated-declarations \
    -Wno-unused-variable \
    -Wno-nullability-completeness

# ← 关键修复：添加 QuartzCore（CABasicAnimation 学习模式脉冲动画需要）
AdBlock_FRAMEWORKS = UIKit QuartzCore

AdBlock_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

internal-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries
	@cp $(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/
