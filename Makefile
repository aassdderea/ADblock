TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AdBlock
AdBlock_FILES = Tweak.m

# TrollFools 注入的 dylib 不需要链接 substrate
# 添加必要的编译标志和框架
AdBlock_CFLAGS = -fobjc-arc \
    -Wno-deprecated-declarations \
    -Wno-unused-variable \
    -Wno-nullability-completeness

AdBlock_FRAMEWORKS = UIKit QuartzCore

# ← 修改：安装路径改为通用位置（仅用于 staging 打包）
# TrollFools 注入时不关心这个路径，但保留以便 make package 正常工作
AdBlock_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk

# ← 修改：staging 输出到更方便取用的位置
internal-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/usr/lib
	@cp $(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib $(THEOS_STAGING_DIR)/usr/lib/
	@echo "✅ dylib 已生成: $(THEOS_STAGING_DIR)/usr/lib/$(LIBRARY_NAME).dylib"
	@echo "📦 请使用 TrollFools 将此文件注入到目标 App"
