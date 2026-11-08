export LOGOS_DEFAULT_GENERATOR = internal

TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = RedditApp Reddit

ARCHS = arm64

PACKAGE_VERSION = 1.3.7
# Shown in the About section of the settings screen (saved before the app version gets added below)
RF_VERSION := $(PACKAGE_VERSION)
ifdef APP_VERSION
  PACKAGE_VERSION := $(APP_VERSION)-$(PACKAGE_VERSION)
endif

ifeq ($(SIDELOADED),1)
  export MODULES = jailed
  CODESIGN_IPA = 0
  # Copied into the app. Made before packaging from layout/ plus the Info.plist changes below.
  RESOURCES_DIR = $(CURDIR)/.theos/ipa-resources
endif

# Safari extension that opens Reddit links in the app: included unless you build with SAFARI_EXTENSION=0
SAFARI_EXTENSION ?= 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedditFilter

$(TWEAK_NAME)_FILES = $(wildcard *.x*) $(wildcard *.m)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Iinclude -Wno-module-import-in-extern-c
$(TWEAK_NAME)_FRAMEWORKS = UIKit WebKit SafariServices Network UniformTypeIdentifiers

$(TWEAK_NAME)_CFLAGS += -DRF_VERSION='"$(RF_VERSION)"'

# Sideloaded builds log in through the browser even from the app's own login form (LoginHelper.x)
ifeq ($(SIDELOADED),1)
  $(TWEAK_NAME)_CFLAGS += -DRF_SIDELOADED=1
endif

# Login notes in the device log (Tweak.xm): off unless you build with DEBUG_MENU=1.
# The Diagnostics section is in every build, behind its own switch.
ifeq ($(DEBUG_MENU),1)
  $(TWEAK_NAME)_CFLAGS += -DREDDITFILTER_DEBUG=1
endif
$(TWEAK_NAME)_INJECT_DYLIBS = $(THEOS_OBJ_DIR)/RedditSideloadFix.dylib

ifeq ($(SIDELOADED),1)
  SUBPROJECTS += RedditSideloadFix
  ifeq ($(SAFARI_EXTENSION),1)
    SUBPROJECTS += SafariExtension
    $(TWEAK_NAME)_EMBED_EXTENSIONS = $(THEOS_OBJ_DIR)/RedditFilterSafari.appex
  endif
  include $(THEOS_MAKE_PATH)/aggregate.mk
endif

include $(THEOS_MAKE_PATH)/tweak.mk


ifeq ($(SIDELOADED),1)
# The app's Info.plist gets the redditfilter:// link type (see SafariLinks.x), and the extension
# gets the app's version, as iOS expects.
before-package::
	@rm -rf "$(RESOURCES_DIR)" && mkdir -p "$(RESOURCES_DIR)"
	@cp -R "layout/Library/Application Support/." "$(RESOURCES_DIR)/"
	@SafariExtension/prepare-ipa.sh "$(IPA)" "$(RESOURCES_DIR)" \
		"$(if $(filter 1,$(SAFARI_EXTENSION)),$(THEOS_OBJ_DIR)/RedditFilterSafari.appex)"
endif
