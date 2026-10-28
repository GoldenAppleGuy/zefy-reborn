THEOS ?= /opt/theos
TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES = Spotify
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# Package architecture follows the scheme: rootless (iphoneos-arm64), roothide (iphoneos-arm64e, needs
# roothide's Theos) or rootful (iphoneos-arm). Build rootful with: make package THEOS_PACKAGE_SCHEME=
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
THEOS_PACKAGE_ARCH = iphoneos-arm64
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
THEOS_PACKAGE_ARCH = iphoneos-arm64e
else
THEOS_PACKAGE_ARCH = iphoneos-arm
endif

TWEAK_NAME = ZefyReborn
ZefyReborn_FILES = Tweak.x
ZefyReborn_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ZefyReborn_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# The layout is written for rootless. The shell files start with an interpreter path that cannot be worked out
# at run time, so for the other schemes they are rewritten here: rootful drops the /var/jb prefix, and roothide
# uses the plain interpreter and ships without the install and removal scripts and the RemoteCompanion add-on
# (they hard-code paths). The zefy command finds its own root from where it is installed.
ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
before-package::
	$(ECHO_NOTHING)sed -i.bak '1s|.*|#!/bin/sh|' $(THEOS_STAGING_DIR)/usr/bin/zefy$(ECHO_END)
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	$(ECHO_NOTHING)rm -rf $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postrm $(THEOS_STAGING_DIR)/Library/RemoteCompanion$(ECHO_END)
else
	$(ECHO_NOTHING)sed -i.bak -e '1s|.*|#!/bin/sh|' -e 's|/var/jb||g' $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postrm$(ECHO_END)
	$(ECHO_NOTHING)sed -i.bak 's|/var/jb||g' $(THEOS_STAGING_DIR)/Library/RemoteCompanion/AddOns/zefy.json$(ECHO_END)
endif
	$(ECHO_NOTHING)find $(THEOS_STAGING_DIR) -name '*.bak' -delete$(ECHO_END)
endif
