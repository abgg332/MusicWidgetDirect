# MusicWidgetDirect —— 桌面小组件按钮直控
#
# TARGET 固定 iphone:clang:16.5:16.0 —— 16.5 的 SDK 编出来的包在 15/16/17 上都能跑。
# ARCHS 两个都要：arm64 给老设备，arm64e 给 A12 及以上（缺了会提示架构不匹配）。

TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MusicWidgetDirect

# 注意：源文件是 .mm，不走 Logos（%hook 不会展开），hook 全部手写在 Tweak.mm 里。
MusicWidgetDirect_FILES = Tweak.mm
MusicWidgetDirect_CFLAGS = -fobjc-arc -std=c++17 -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations
MusicWidgetDirect_FRAMEWORKS = UIKit Foundation
MusicWidgetDirect_LDFLAGS = -F$(THEOS_VENDOR_LIBRARY_PATH) -framework CydiaSubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

# 本地 make install 时自动注销桌面（CI 出包不受影响）
after-install::
	install.exec "killall -9 SpringBoard"
