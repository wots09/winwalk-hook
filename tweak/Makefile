TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WinwalkHook
WinwalkHook_FILES = Tweak.x
WinwalkHook_CFLAGS = -fobjc-arc
WinwalkHook_LDFLAGS = -lfishhook
WinwalkHook_FRAMEWORKS = Foundation UIKit
WinwalkHook_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk

after-WinwalkHook-all::
	cp $(THEOS_OBJ_DIR)/WinwalkHook.dylib $(THEOS)/../WinwalkHook.dylib 2>/dev/null || \
	cp $(THEOS_OBJ_DIR)/WinwalkHook.dylib ./
