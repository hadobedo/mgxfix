# RootHide-Theos (~/roothide-theos) with the mixed host-clang toolchain.
# The bundled clang 11 emits an incompatible arm64e ABI — never build with it.
TARGET := iphone:clang:latest:17.0
THEOS_PACKAGE_SCHEME ?= rootless
ARCHS ?= arm64 arm64e
ifeq ($(shell uname -s),Linux)
override TARGET_CC := /home/nick/Documents/iOS/cc-mixed
override TARGET_CXX := /home/nick/Documents/iOS/cxx-mixed
override TARGET_LD := /home/nick/Documents/iOS/cxx-mixed
endif

include $(THEOS)/makefiles/common.mk

# Injects into GameControllerConfigService only — the process that loads the
# GameController device database and its personalities.
TWEAK_NAME = MGXFix
MGXFix_FILES = Tweak.xm
MGXFix_FRAMEWORKS = Foundation
MGXFix_LDFLAGS = -F$(THEOS)/vendor/lib -framework CydiaSubstrate
MGXFix_CFLAGS = -fobjc-arc -Wall -Wextra -Werror

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
MGXFix_LDFLAGS += -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks
endif

include $(THEOS_MAKE_PATH)/tweak.mk
