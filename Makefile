TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdBlock
AdBlock_FILES = Tweak.xm
AdBlock_CFLAGS = -fobjc-arc
AdBlock_FRAMEWORKS = UIKit

# 关键：指定安装路径，防止 Theos 尝试打包 deb 时寻找 filter plist
AdBlock_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

# 关键：覆盖默认的 stage 规则，跳过 plist 检查，直接复制 dylib
internal-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries
	@cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/
