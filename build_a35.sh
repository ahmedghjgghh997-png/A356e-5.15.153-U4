#!/bin/bash
# ============================================================
# سكريبت نظيف لبناء نواة Samsung A35 (بدون أي تعديلات)
# فقط defconfig + make Image
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
    V=1
    NO_YAML=1
)

if ! command -v ld.lld &> /dev/null; then
    sudo ln -sf $(which ld.lld-18) /usr/local/bin/ld.lld
    export PATH=/usr/local/bin:$PATH
fi

build_kernel() {
    echo "[INFO] استخدام defconfig: s5e8835-a35xjvxx_defconfig"
    make "${BUILD_OPTIONS[@]}" s5e8835-a35xjvxx_defconfig

    echo "[INFO] بدء تجميع النواة (بدون أي تعديلات)..."
    make "${BUILD_OPTIONS[@]}" Image 2>&1 | tee build.log

    if [ -f "arch/arm64/boot/Image" ]; then
        mkdir -p build
        cp arch/arm64/boot/Image build/
        echo -e "\n[SUCCESS] تم بناء Image بنجاح!"
        echo "Image: build/Image"
    else
        echo "[ERROR] لم يتم العثور على Image!"
        echo "محتويات arch/arm64/boot:"
        ls -la arch/arm64/boot/
        exit 1
    fi
}

build_kernel
