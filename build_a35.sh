#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380)
# مع دمج KernelSU-Next + SusFS (مع إمكانية تعطيل SusFS مؤقتًا)
# ============================================================

export ARCH=arm64
export KERNEL_ROOT="$(pwd)"
export KBUILD_BUILD_USER="Ahmed"

export TARGET_SOC=s5e8835
export PLATFORM_VERSION=14
export ANDROID_MAJOR_VERSION=u

export CC=clang-18
export LD=ld.lld-18
export HOSTLD=ld.lld-18
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_TRIPLE=aarch64-linux-gnu-

export BUILD_OPTIONS=(
    -C "${KERNEL_ROOT}"
    -j$(nproc)
    ARCH=arm64
    CC=${CC}
    LD=${LD}
    HOSTLD=${HOSTLD}
    CROSS_COMPILE=${CROSS_COMPILE}
    CLANG_TRIPLE=${CLANG_TRIPLE}
    LLVM=1
    LLVM_IAS=1
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    READELF=llvm-readelf
    STRIP=llvm-strip
    HOSTCC=clang-18
    HOSTCXX=clang++-18
    V=1
    NO_YAML=1
)

if ! command -v ld.lld &> /dev/null; then
    sudo ln -sf $(which ld.lld-18) /usr/local/bin/ld.lld
    export PATH=/usr/local/bin:$PATH
fi

remove_gcc_wrapper() {
    grep -q "REAL_CC" Makefile && sed -i '/REAL_CC/d' Makefile
    grep -q "CFP_CC" Makefile && sed -i '/CFP_CC/d' Makefile
    grep -q "wrapper" Makefile && sed -i '/wrapper/d' Makefile
}

apply_patches() {
    [ -d "patches" ] && for p in patches/*.patch; do
        [ -f "$p" ] || continue
        git apply --check "$p" && git apply "$p" || echo "Patch $p already applied"
    done
}

prepare_stock_defconfig() {
    [ -f "arch/arm64/configs/stock_defconfig" ] || \
        cp arch/arm64/configs/s5e8835-a35xjvxx_defconfig arch/arm64/configs/stock_defconfig
}

enable_kprobes() {
    scripts/config --file ".config" -e CONFIG_KPROBES -e CONFIG_HAVE_KPROBES -e CONFIG_KPROBE_EVENTS
    # تفعيل خيارات SusFS (اختياري)
    scripts/config --file ".config" -e CONFIG_KSU_SUSFS \
                                   -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT \
                                   -e CONFIG_KSU_SUSFS_SUS_PATH \
                                   -e CONFIG_KSU_SUSFS_SPOOF_UNAME \
                                   -e CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS 2>/dev/null || true
}

disable_samsung_security() {
    scripts/config --file ".config" -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
        -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE
    scripts/config --file ".config" --disable CONFIG_MODULE_SIG_FORCE
}

add_kernelsu() {
    if [ ! -d "KernelSU-Next" ]; then
        echo "[INFO] دمج KernelSU-Next (فرع next-susfs)..."
        curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next-susfs/kernel/setup.sh" | bash -
    else
        echo "[INFO] KernelSU-Next موجود مسبقًا"
    fi
}

# تعطيل تطبيق SusFS مؤقتًا إذا تسبب في مشاكل
APPLY_SUSFS=${APPLY_SUSFS:-false}  # غيّر إلى true إذا أردت تفعيله
apply_susfs() {
    if [ "$APPLY_SUSFS" = "true" ] && [ ! -d "susfs4ksu" ]; then
        echo "[INFO] تطبيق تصحيحات SusFS..."
        git clone https://gitlab.com/simonpunk/susfs4ksu.git
        cd KernelSU-Next
        for patch in ../susfs4ksu/kernel_patches/*.patch; do
            echo "تطبيق: $(basename $patch)"
            patch -p1 < "$patch" || echo "فشل (قد يكون مطبقًا)"
        done
        cd ..
    fi
}

merge_custom_config() {
    [ -f "custom.config" ] && scripts/kconfig/merge_config.sh -m -O . .config custom.config
}

prepare_anykernel3() {
    [ -d "AnyKernel3" ] && (cd AnyKernel3 && git pull) || \
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
}

create_anykernel3_zip() {
    cp build/Image AnyKernel3/
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
}

build_kernel() {
    echo "[INFO] استخدام defconfig: s5e8835-a35xjvxx_defconfig"
    make "${BUILD_OPTIONS[@]}" s5e8835-a35xjvxx_defconfig

    prepare_stock_defconfig
    merge_custom_config
    remove_gcc_wrapper
    apply_patches
    enable_kprobes
    add_kernelsu
    apply_susfs   # يمكن تعطيله بتغيير APPLY_SUSFS=false

    # تعطيل BTF
    scripts/config --file ".config" --disable CONFIG_DEBUG_INFO_BTF --disable CONFIG_DEBUG_INFO
    make "${BUILD_OPTIONS[@]}" olddefconfig

    echo "[INFO] بدء تجميع النواة (قد يستغرق وقتًا)..."
    make "${BUILD_OPTIONS[@]}" Image 2>&1 | tee build.log

    # البحث عن Image
    IMAGE_FILE=""
    if [ -f "arch/arm64/boot/Image" ]; then
        IMAGE_FILE="arch/arm64/boot/Image"
    elif [ -f "arch/arm64/boot/Image.gz" ]; then
        IMAGE_FILE="arch/arm64/boot/Image.gz"
        echo "[INFO] تم العثور على Image.gz بدلاً من Image"
    elif [ -f "arch/arm64/boot/Image.lz4" ]; then
        IMAGE_FILE="arch/arm64/boot/Image.lz4"
        echo "[INFO] تم العثور على Image.lz4 بدلاً من Image"
    else
        echo "[ERROR] لم يتم العثور على Image!"
        echo "محتويات arch/arm64/boot:"
        ls -la arch/arm64/boot/ 2>/dev/null || echo "المجلد غير موجود"
        echo "آخر 50 سطرًا من build.log:"
        tail -50 build.log
        exit 1
    fi

    mkdir -p build
    cp "$IMAGE_FILE" build/

    # magiskboot
    if ! command -v magiskboot &> /dev/null; then
        mkdir -p tools/magisk && cd tools/magisk
        wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
        unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libmagiskboot.so' -d .
        mv libmagiskboot.so magiskboot && chmod +x magiskboot
        sudo cp magiskboot /usr/local/bin/ 2>/dev/null || cp magiskboot $HOME/.local/bin/
        export PATH="$HOME/.local/bin:$PATH"
        cd ../..
    fi

    if [ -f "stock_boot/boot.img" ]; then
        mkdir -p boot_work && cp stock_boot/boot.img boot_work/ && cd boot_work
        magiskboot unpack boot.img
        cp ../build/Image kernel
        magiskboot repack boot.img
        mv new-boot.img ../build/boot.img
        cd ..
        echo "[SUCCESS] boot.img created"
    else
        echo "[WARN] No stock boot.img, only Image built"
    fi

    prepare_anykernel3
    create_anykernel3_zip

    echo -e "\n[SUCCESS] Build completed!"
    echo "Image: build/$(basename "$IMAGE_FILE")"
    [ -f "build/boot.img" ] && echo "boot.img: build/boot.img"
    ls build/AnyKernel3-*.zip && echo "AnyKernel3.zip: build/AnyKernel3-*.zip"
}

build_kernel
