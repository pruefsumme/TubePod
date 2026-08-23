ARCHS = armv7
# Build with the legacy armv7 SDK while retaining an iOS 6.0 deployment target.
TARGET = iphone:clang:6.1:6.0
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TubePod
TubePod_FILES = Tweak.xm TPBridge.m TPDatabase.m TPDownloader.m TPImporter.m TPPrivate.m
TubePod_USE_MODULES = 0
TubePod_CFLAGS = -fobjc-arc -Werror -Wall -Wextra -Wno-deprecated-declarations -Wno-cast-function-type-mismatch
TubePod_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia AudioToolbox
TubePod_LIBRARIES = substrate sqlite3
# StoreServices is loaded and selector-checked at runtime, so no private SDK
# link stub is required.
TubePod_LDFLAGS = -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/tweak.mk
