TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WinwalkHook
WinwalkHook_FILES = Tweak.x fishhook.c
WinwalkHook_CFLAGS = -fobjc-arc
WinwalkHook_FRAMEWORKS = Foundation UIKit
WinwalkHook_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
