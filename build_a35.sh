#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380)
# مع KernelSU + KPROBES + Clang-18 + AnyKernel3 + boot.img
# ============================================================

export ARCH=arm64
export KERNEL_ROOT="$(pwd)"
export KBUILD_BUILD_USER="Ahmed"

export TARGET_SOC=s5e8835
export PLATFORM_VERSION=14
export ANDROID_MAJOR_VERSION=u

export CC=clang-18
export LD=ld.lld-18
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_TRIPLE=aarch64-linux-gnu-

export BUILD_OPTIONS=(
    -C "${KERNEL_ROOT}"
    -j$(nproc)
    ARCH=arm64
    CC=${CC}
    LD=${LD}
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
)

remove_gcc_wrapper() {
    if grep -q "REAL_CC" Makefile; then
        sed -i '/REAL_CC/d' Makefile
    fi
    if grep -q "CFP_CC" Makefile; then
        sed -i '/CFP_CC/d' Makefile
    fi
    if grep -q "wrapper" Makefile; then
        sed -i '/wrapper/d' Makefile
    fi
}

apply_additional_patches() {
    if [ -d "patches" ]; then
        echo "[INFO] تطبيق الباتشات من مجلد patches/"
        for patch in patches/*.patch; do
            [ -f "$patch" ] || continue
            echo "  -> تطبيق $(basename $patch)"
            git apply --check "$patch" && git apply "$patch" || echo "     (فشل أو مطبق مسبقاً)"
        done
    else
        echo "[INFO] لا يوجد مجلد patches، تخطي"
    fi
}

prepare_stock_defconfig() {
    if [ ! -f "arch/arm64/configs/stock_defconfig" ]; then
        echo "[INFO] إنشاء stock_defconfig من defconfig الأصلي"
        cp arch/arm64/configs/s5e8835-a35xjvxx_defconfig arch/arm64/configs/stock_defconfig
    fi
}

enable_kprobes() {
    echo "[INFO] تفعيل KPROBES لدعم KernelSU..."
    scripts/config --file ".config" \
        -e CONFIG_KPROBES \
        -e CONFIG_HAVE_KPROBES \
        -e CONFIG_KPROBE_EVENTS
}

disable_samsung_security() {
    echo "[INFO] تعطيل حماية Samsung (RKP, Knox, DEFEX, FIVE, PROCA)..."
    scripts/config --file ".config" \
        -d CONFIG_UH \
        -d CONFIG_UH_RKP \
        -d CONFIG_RKP_CFP \
        -d CONFIG_SECURITY_DEFEX \
        -d CONFIG_PROCA \
        -d CONFIG_FIVE
    echo "[INFO] تعطيل فحص CRC لضمان عمل الـ Wi-Fi واللمس..."
    scripts/config --file ".config" --disable CONFIG_MODULE_SIG_FORCE
}

add_kernelsu() {
    if [ ! -d "KernelSU" ]; then
        echo "[INFO] إضافة KernelSU..."
        curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
    else
        echo "[INFO] KernelSU موجود مسبقاً"
    fi
}

merge_custom_config() {
    if [ -f "custom.config" ]; then
        echo "[INFO] دمج custom.config مع الإعدادات الأساسية..."
        scripts/kconfig/merge_config.sh -m -O . .config custom.config
    fi
}

prepare_anykernel3() {
    if [ ! -d "AnyKernel3" ]; then
        echo "[INFO] استنساخ AnyKernel3 من osm0sis..."
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    else
        echo "[INFO] AnyKernel3 موجود مسبقاً، تحديث..."
        cd AnyKernel3 && git pull && cd ..
    fi
}

create_anykernel3_zip() {
    echo "[INFO] إنشاء حزمة AnyKernel3.zip..."
    cp build/Image AnyKernel3/
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
    echo "[SUCCESS] تم إنشاء AnyKernel3.zip في مجلد build/"
}

build_kernel() {
    echo "[INFO] استخدام defconfig: s5e8835-a35xjvxx_defconfig"
    make "${BUILD_OPTIONS[@]}" s5e8835-a35xjvxx_defconfig

    prepare_stock_defconfig
    merge_custom_config
    remove_gcc_wrapper
    apply_additional_patches
    enable_kprobes
    add_kernelsu

    echo "[INFO] تعيين خيارات KernelSU تلقائياً..."
    if [ -f ".config" ]; then
        scripts/config --file ".config" -e CONFIG_KSU -d CONFIG_KSU_DEBUG -d CONFIG_KSU_DISABLE_MANAGER
        make "${BUILD_OPTIONS[@]}" olddefconfig
    fi

    if [ -n "$GITHUB_ACTIONS" ] || [ -n "$CI" ]; then
        echo "[INFO] بيئة CI، تخطي menuconfig."
    else
        echo "[INFO] فتح menuconfig للتعديل اليدوي..."
        make "${BUILD_OPTIONS[@]}" menuconfig
    fi

    disable_samsung_security

    echo "[INFO] بدء تجميع النواة..."
    make "${BUILD_OPTIONS[@]}" Image 2>&1 | tee build.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "[ERROR] فشل تجميع النواة. آخر 30 سطرًا من السجل:"
        tail -30 build.log
        exit 1
    fi

    mkdir -p build
    cp arch/arm64/boot/Image build/

    if ! command -v magiskboot &> /dev/null; then
        echo "[INFO] تثبيت magiskboot..."
        mkdir -p tools/magisk
        cd tools/magisk
        wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
        unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libmagiskboot.so' -d .
        mv libmagiskboot.so magiskboot
        chmod +x magiskboot
        sudo cp magiskboot /usr/local/bin/ 2>/dev/null || cp magiskboot $HOME/.local/bin/
        export PATH="$HOME/.local/bin:$PATH"
        cd ../..
    fi

    if [ -f "stock_boot/boot.img" ]; then
        echo "[INFO] بناء boot.img..."
        mkdir -p boot_work
        cp stock_boot/boot.img boot_work/
        cd boot_work
        magiskboot unpack boot.img
        cp ../build/Image kernel
        magiskboot repack boot.img
        mv new-boot.img ../build/boot.img
        cd ..
        echo "[SUCCESS] تم إنشاء boot.img"
    else
        echo "[WARN] لا يوجد stock_boot/boot.img، Image فقط."
    fi

    prepare_anykernel3
    create_anykernel3_zip

    echo -e "\n[SUCCESS] تم التجميع بنجاح!"
    echo "Image: build/Image"
    [ -f "build/boot.img" ] && echo "boot.img: build/boot.img"
    ls build/AnyKernel3-*.zip && echo "AnyKernel3.zip موجود"
}

build_kernel
