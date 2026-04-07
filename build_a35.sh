#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380)
# مع KernelSU + AnyKernel3 + boot.img + تعطيل الحماية
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

# ===========================
# دالة إزالة حماية سامسونج (Wrapper)
# ===========================
remove_gcc_wrapper() {
    grep -q "REAL_CC" Makefile && sed -i '/REAL_CC/d' Makefile
    grep -q "CFP_CC" Makefile && sed -i '/CFP_CC/d' Makefile
    grep -q "wrapper" Makefile && sed -i '/wrapper/d' Makefile
}

# ===========================
# دالة تطبيق الباتشات الإضافية
# ===========================
apply_patches() {
    [ -d "patches" ] && for p in patches/*.patch; do
        [ -f "$p" ] || continue
        git apply --check "$p" && git apply "$p" || echo "Patch $p already applied"
    done
}

# ===========================
# دالة إنشاء stock_defconfig
# ===========================
prepare_stock_defconfig() {
    [ -f "arch/arm64/configs/stock_defconfig" ] || \
        cp arch/arm64/configs/s5e8835-a35xjvxx_defconfig arch/arm64/configs/stock_defconfig
}

# ===========================
# دالة تفعيل KPROBES (لـ KernelSU)
# ===========================
enable_kprobes() {
    scripts/config --file ".config" -e CONFIG_KPROBES -e CONFIG_HAVE_KPROBES -e CONFIG_KPROBE_EVENTS
}

# ===========================
# دالة تعطيل حماية سامسونج
# ===========================
disable_samsung_security() {
    scripts/config --file ".config" -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
        -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE
    scripts/config --file ".config" --disable CONFIG_MODULE_SIG_FORCE
}

# ===========================
# دالة دمج KernelSU
# ===========================
add_kernelsu() {
    if [ ! -d "KernelSU" ]; then
        echo "[INFO] جاري دمج KernelSU..."
        curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
    else
        echo "[INFO] KernelSU موجود مسبقًا"
    fi
}

# ===========================
# دالة دمج custom.config
# ===========================
merge_custom_config() {
    [ -f "custom.config" ] && scripts/kconfig/merge_config.sh -m -O . .config custom.config
}

# ===========================
# دالة تجهيز AnyKernel3
# ===========================
prepare_anykernel3() {
    [ -d "AnyKernel3" ] && (cd AnyKernel3 && git pull) || \
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
}

# ===========================
# دالة إنشاء حزمة AnyKernel3
# ===========================
create_anykernel3_zip() {
    cp build/Image AnyKernel3/
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
}

# ===========================
# دالة البناء الرئيسية
# ===========================
build_kernel() {
    echo "=== بدء عملية البناء ==="
    echo "1. تحضير defconfig: s5e8835-a35xjvxx_defconfig"
    make "${BUILD_OPTIONS[@]}" s5e8835-a35xjvxx_defconfig

    echo "2. تجهيز stock_defconfig ودمج custom.config"
    prepare_stock_defconfig
    merge_custom_config

    echo "3. إزالة GCC wrapper وتطبيق الباتشات"
    remove_gcc_wrapper
    apply_patches

    echo "4. تفعيل KPROBES"
    enable_kprobes

    echo "5. دمج KernelSU"
    add_kernelsu

    echo "6. تعطيل حماية سامسونج"
    disable_samsung_security

    echo "7. تعطيل BTF (لتجنب أخطاء resolve_btfids)"
    scripts/config --file ".config" --disable CONFIG_DEBUG_INFO_BTF --disable CONFIG_DEBUG_INFO
    make "${BUILD_OPTIONS[@]}" olddefconfig

    echo "8. بدء تجميع النواة (قد يستغرق وقتًا)..."
    make "${BUILD_OPTIONS[@]}" Image 2>&1 | tee build.log

    echo "9. البحث عن Image"
    if [ -f "arch/arm64/boot/Image" ]; then
        mkdir -p build
        cp arch/arm64/boot/Image build/
        echo "[SUCCESS] تم إنشاء Image"
    elif [ -f "arch/arm64/boot/Image.gz" ]; then
        mkdir -p build
        cp arch/arm64/boot/Image.gz build/
        echo "[SUCCESS] تم إنشاء Image.gz"
    else
        echo "[ERROR] لم يتم العثور على Image!"
        echo "محتويات arch/arm64/boot:"
        ls -la arch/arm64/boot/
        echo "آخر 50 سطرًا من build.log:"
        tail -50 build.log
        exit 1
    fi

    echo "10. تجهيز magiskboot (لإنشاء boot.img)"
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
        echo "11. بناء boot.img"
        mkdir -p boot_work && cp stock_boot/boot.img boot_work/ && cd boot_work
        magiskboot unpack boot.img
        cp ../build/Image kernel
        magiskboot repack boot.img
        mv new-boot.img ../build/boot.img
        cd ..
        echo "[SUCCESS] تم إنشاء boot.img"
    else
        echo "[WARN] لا يوجد stock_boot/boot.img، تم بناء Image فقط"
    fi

    echo "12. إنشاء AnyKernel3.zip"
    prepare_anykernel3
    create_anykernel3_zip

    echo -e "\n[SUCCESS] انتهى البناء بنجاح!"
    echo "Image: build/Image"
    [ -f "build/boot.img" ] && echo "boot.img: build/boot.img"
    ls build/AnyKernel3-*.zip && echo "AnyKernel3.zip: build/AnyKernel3-*.zip"
}

build_kernel
