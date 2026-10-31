include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = KeyboardSkinPrefs
KeyboardSkinPrefs_FILES = RootListController.m
KeyboardSkinPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I.
KeyboardSkinPrefs_FRAMEWORKS = UIKit Foundation
KeyboardSkinPrefs_PRIVATE_FRAMEWORKS = Preferences
KeyboardSkinPrefs_INSTALL_PATH = /Library/PreferenceBundles
KeyboardSkinPrefs_RESOURCE_FILES = Resources/Root.plist Resources/Info.plist Resources/icon.png Resources/icon@2x.png Resources/icon@3x.png

include $(THEOS_MAKE_PATH)/bundle.mk
