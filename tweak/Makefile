TARGET := iphone:clang:latest:14.0
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = WinwalkHook
WinwalkHook_FILES = Tweak.x
WinwalkHook_CFLAGS = -fobjc-arc
WinwalkHook_FRAMEWORKS = Foundation
WinwalkHook_INSTALL_PATH = /usr/lib
include $(THEOS_MAKE_PATH)/library.mk
