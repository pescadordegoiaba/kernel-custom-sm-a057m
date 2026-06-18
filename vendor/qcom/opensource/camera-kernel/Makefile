# Makefile for use with Android's kernel/build system

CAMERA_KERNEL_ROOT := $(shell pwd)
KERNEL_ROOT_PATH := $(ROOT_DIR)/$(KERNEL_DIR)

all: modules

modules dtbs:
	$(MAKE) -C $(KERNEL_SRC) M=$(M) modules \
		CAMERA_KERNEL_ROOT='$(CAMERA_KERNEL_ROOT)' \
		KERNEL_ROOT='$(KERNEL_ROOT_PATH)' \
		MODNAME=camera

modules_install:
	$(MAKE) M=$(M) -C $(KERNEL_SRC) modules_install

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(M) clean
