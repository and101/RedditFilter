TARGET := iphone:clang:latest:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPEX_NAME = RedditFilterSafari

$(APPEX_NAME)_FILES = SafariWebExtensionHandler.m
$(APPEX_NAME)_CFLAGS = -fobjc-arc
$(APPEX_NAME)_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/appex.mk
