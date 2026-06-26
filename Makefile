TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

# 使用 library 模板（生成纯净 .dylib，不链接 substrate）
LIBRARY_NAME = AdBlock
AdBlock_FILES = Tweak.m
AdBlock_CFLAGS = -fobjc-arc
AdBlock_FRAMEWORKS = UIKit

# 安装路径仅用于 staging 目录结构（非必须，但保留）
AdBlock_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

# 复制最终 dylib 到 staging 目录
internal-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries
	@cp $(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/
