ZIGFLAGS := -Doptimize=ReleaseSafe
GIT_COMMIT := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
KERNEL_BUILD_FLAGS := $(ZIGFLAGS) -Dgit_commit=$(GIT_COMMIT)

ISO_X86_64_DIR := iso_root-x86_64
ISO_X86_64_PANIC_DIR := iso_root-x86_64-panic-smoke
ISO_AARCH64_DIR := iso_root-aarch64
ISO_X86_64_FILE := zernel-x86_64.iso
ISO_X86_64_PANIC_FILE := zernel-x86_64-panic-smoke.iso
ISO_AARCH64_FILE := zernel-aarch64.iso
KERNEL_X86_64_BIN := kernel/zig-out/bin/kernel-x86_64
KERNEL_X86_64_PANIC_BIN := kernel/zig-out/bin/kernel-x86_64-panic-smoke
KERNEL_AARCH64_BIN := kernel/zig-out/bin/kernel-aarch64

.PHONY: all
all: iso-x86_64

boot/limine:
	git clone https://codeberg.org/Limine/Limine.git \
		--branch=v9.x-binary --depth=1               \
		boot/limine
	$(MAKE) -C boot/limine

.PHONY: kernel
kernel: kernel-x86_64

.PHONY: kernel-x86_64
kernel-x86_64:
	cd kernel && zig build $(KERNEL_BUILD_FLAGS) -Darch=x86_64

.PHONY: kernel-x86_64-panic-smoke
kernel-x86_64-panic-smoke:
	cd kernel && zig build $(KERNEL_BUILD_FLAGS) -Darch=x86_64 -Dpanic_smoke=true

.PHONY: kernel-aarch64
kernel-aarch64:
	cd kernel && zig build $(KERNEL_BUILD_FLAGS) -Darch=aarch64

.PHONY: kernel-all
kernel-all: kernel-x86_64 kernel-aarch64

.PHONY: test
test:
	cd kernel && zig test src/tests.zig

.PHONY: check
check: test
	$(MAKE) kernel-all

.PHONY: smoke-x86_64
smoke-x86_64: $(ISO_X86_64_FILE)
	./scripts/boot-smoke-x86_64.sh $(ISO_X86_64_FILE)

.PHONY: smoke-panic-x86_64
smoke-panic-x86_64: $(ISO_X86_64_PANIC_FILE)
	./scripts/panic-smoke-x86_64.sh $(ISO_X86_64_PANIC_FILE)

.PHONY: check-smoke
check-smoke: check smoke-x86_64 smoke-panic-x86_64

.PHONY: iso-x86_64
iso-x86_64: $(ISO_X86_64_FILE)

.PHONY: iso-aarch64
iso-aarch64: $(ISO_AARCH64_FILE)

.PHONY: iso-all
iso-all: iso-x86_64 iso-aarch64

$(ISO_X86_64_FILE): boot/limine kernel-x86_64
	rm -rf $(ISO_X86_64_DIR)
	mkdir -p $(ISO_X86_64_DIR)/EFI/BOOT

	cp boot/limine.conf $(ISO_X86_64_DIR)
	cp $(KERNEL_X86_64_BIN) $(ISO_X86_64_DIR)/kernel

	cp boot/limine/limine-bios.sys    \
	   boot/limine/limine-bios-cd.bin \
	   boot/limine/limine-uefi-cd.bin \
	   $(ISO_X86_64_DIR)

	cp boot/limine/BOOTX64.EFI \
	   boot/limine/BOOTIA32.EFI \
	   $(ISO_X86_64_DIR)/EFI/BOOT/

	xorriso -as mkisofs -R -r -J -b limine-bios-cd.bin                \
		-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus     \
		-apm-block-size 2048 --efi-boot limine-uefi-cd.bin            \
		-efi-boot-part --efi-boot-image --protective-msdos-label      \
		$(ISO_X86_64_DIR) -o $(ISO_X86_64_FILE)

	./boot/limine/limine bios-install $(ISO_X86_64_FILE)
	rm -rf $(ISO_X86_64_DIR)

$(ISO_X86_64_PANIC_FILE): boot/limine kernel-x86_64-panic-smoke
	rm -rf $(ISO_X86_64_PANIC_DIR)
	mkdir -p $(ISO_X86_64_PANIC_DIR)/EFI/BOOT

	cp boot/limine.conf $(ISO_X86_64_PANIC_DIR)
	cp $(KERNEL_X86_64_PANIC_BIN) $(ISO_X86_64_PANIC_DIR)/kernel

	cp boot/limine/limine-bios.sys    \
	   boot/limine/limine-bios-cd.bin \
	   boot/limine/limine-uefi-cd.bin \
	   $(ISO_X86_64_PANIC_DIR)

	cp boot/limine/BOOTX64.EFI \
	   boot/limine/BOOTIA32.EFI \
	   $(ISO_X86_64_PANIC_DIR)/EFI/BOOT/

	xorriso -as mkisofs -R -r -J -b limine-bios-cd.bin                \
		-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus     \
		-apm-block-size 2048 --efi-boot limine-uefi-cd.bin            \
		-efi-boot-part --efi-boot-image --protective-msdos-label      \
		$(ISO_X86_64_PANIC_DIR) -o $(ISO_X86_64_PANIC_FILE)

	./boot/limine/limine bios-install $(ISO_X86_64_PANIC_FILE)
	rm -rf $(ISO_X86_64_PANIC_DIR)

$(ISO_AARCH64_FILE): boot/limine kernel-aarch64
	rm -rf $(ISO_AARCH64_DIR)
	mkdir -p $(ISO_AARCH64_DIR)/EFI/BOOT

	cp boot/limine.conf $(ISO_AARCH64_DIR)
	cp $(KERNEL_AARCH64_BIN) $(ISO_AARCH64_DIR)/kernel

	cp boot/limine/limine-uefi-cd.bin $(ISO_AARCH64_DIR)
	cp boot/limine/BOOTAA64.EFI $(ISO_AARCH64_DIR)/EFI/BOOT/

	xorriso -as mkisofs -R -r -J -hfsplus                            \
		-apm-block-size 2048 --efi-boot limine-uefi-cd.bin            \
		-efi-boot-part --efi-boot-image --protective-msdos-label      \
		$(ISO_AARCH64_DIR) -o $(ISO_AARCH64_FILE)

	rm -rf $(ISO_AARCH64_DIR)

.PHONY: run
run: run-x86_64

.PHONY: run-x86_64
run-x86_64: $(ISO_X86_64_FILE)
	qemu-system-x86_64 -M q35 -m 128M -cdrom $(ISO_X86_64_FILE) -boot d

.PHONY: run-aarch64
run-aarch64: $(ISO_AARCH64_FILE)
	qemu-system-aarch64 -M virt -cpu cortex-a72 -m 128M \
		-bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
		-device ramfb \
		-cdrom $(ISO_AARCH64_FILE) -boot d

.PHONY: debug
debug: debug-x86_64

.PHONY: debug-x86_64
debug-x86_64: $(ISO_X86_64_FILE)
	qemu-system-x86_64 -M q35 -m 128M -cdrom $(ISO_X86_64_FILE) -boot d \
		-serial stdio -no-reboot -no-shutdown

.PHONY: debug-aarch64
debug-aarch64: $(ISO_AARCH64_FILE)
	qemu-system-aarch64 -M virt -cpu cortex-a72 -m 128M \
		-bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
		-device ramfb \
		-cdrom $(ISO_AARCH64_FILE) -boot d \
		-serial stdio -no-reboot -no-shutdown

.PHONY: clean
clean:
	rm -rf $(ISO_X86_64_DIR) $(ISO_X86_64_PANIC_DIR) $(ISO_AARCH64_DIR)
	rm -rf $(ISO_X86_64_FILE) $(ISO_X86_64_PANIC_FILE) $(ISO_AARCH64_FILE)
	rm -rf kernel/.zig-cache kernel/zig-out

.PHONY: distclean
distclean: clean
	rm -rf boot/limine
