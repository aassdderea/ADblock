TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdBlock
AdBlock_FILES = Tweak.xm
AdBlock_CFLAGS = -fobjc-arc
AdBlock_FRAMEWORKS = UIKit

# 如果选择生成纯 dylib 而非 deb 包，取消下面注释
# AdBlock_INSTALL_PATH = /usr/lib/TrollStore

include $(THEOS_MAKE_PATH)/tweak.mk
