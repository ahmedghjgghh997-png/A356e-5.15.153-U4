#!/bin/bash
# build_a35_ksu.sh - Samsung A35 (SM-A356E) GKI 2.0 + KernelSU + Clang fixes

set -e

# ========== الألوان ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ========== مساعدة ==========
show_help() {
    echo "الاستخدام: $0 [خيارات]"
    echo "  --menuconfig    فتح menuconfig قبل البناء"
    echo "  --clean         تنظيف البناء السابق"
    echo "  --use-out       استخدام مجلد out (للهواتف غير Exynos)"
    echo "  --skip-deps     تخطي تثبيت التبعيات"
    echo "  --kernel-only   بناء Image فقط (بدون boot.img)"
    echo "  --help          عرض هذه المساعدة"
    exit 0
}

# ========== تحضير المتغيرات ==========
MENUCONFIG=false
CLEAN_BUILD=false
USE_OUT_DIR=false
SKIP_DEPS=false
KERNEL_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --menuconfig) MENUCONFIG=true ;;
        --clean) CLEAN_BUILD=true ;;
        --use-out) USE_OUT_DIR=true ;;
        --skip-deps) SKIP_DEPS=true ;;
        --kernel-only) KERNEL_ONLY=true ;;
        --help) show_help ;;
        *) echo -e "${RED}خطأ: خيار غير معروف $1${NC}"; show_help ;;
    esac
    shift
done

# ========== البحث عن kernel root ==========
find_kernel_root() {
    if [ -f "Makefile" ] && grep -q "VERSION =" Makefile; then
        echo "$PWD"
        return
    fi
    for dir in common kernel-*; do
        if [ -d "$dir" ] && [ -f "$dir/Makefile" ]; then
            echo "$dir"
            return
        fi
    done
    echo ""
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL_ROOT=$(find_kernel_root)
if [ -z "$KERNEL_ROOT" ]; then
    echo -e "${RED}❌ لم يتم العثور على kernel root. تأكد من وجود Makefile في المجلد الحالي أو داخل common/${NC}"
    exit 1
fi
echo -e "${GREEN}[✓] Kernel root: $KERNEL_ROOT${NC}"
cd "$KERNEL_ROOT"

# ========== تثبيت التبعيات ==========
if [ "$SKIP_DEPS" = false ] && [ ! -f "/tmp/deps_installed" ]; then
    echo "[1/9] تثبيت التبعيات..."
    sudo apt update
    sudo apt install -y git device-tree-compiler lz4 xz-utils zlib1g-dev openjdk-17-jdk \
        gcc g++ python3 python-is-python3 p7zip-full android-sdk-libsparse-utils erofs-utils \
        default-jdk gnupg flex bison gperf build-essential zip curl libc6-dev libncurses-dev \
        libx11-dev libreadline-dev libgl1 libgl1-mesa-dev python3-markdown libxml2-utils xsltproc \
        bc tofrodos make sudo grep libtinfo6 cpio kmod openssl libelf-dev pahole libssl-dev \
        libarchive-tools zstd rsync wget patch --fix-missing
    wget http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb
    sudo dpkg -i libtinfo5_6.3-2ubuntu0.1_amd64.deb || true
    rm -f libtinfo5_6.3-2ubuntu0.1_amd64.deb

    curl -L -o magisk.apk https://github.com/topjohnwu/Magisk/releases/latest/download/Magisk.apk
    unzip -j magisk.apk 'lib/x86_64/libmagiskboot.so' -d .
    mv libmagiskboot.so magiskboot
    chmod +x magiskboot
    sudo cp magiskboot /usr/local/bin/
    rm -f magisk.apk

    touch /tmp/deps_installed
    echo -e "${GREEN}[✓] التبعيات مثبتة${NC}"
fi

# ========== تحميل toolchains ==========
TOOLCHAIN_DIR="$SCRIPT_DIR/toolchains"
mkdir -p "$TOOLCHAIN_DIR"
echo "[2/9] التحقق من وجود toolchains..."
if [ ! -d "$TOOLCHAIN_DIR/clang" ] || [ ! -d "$TOOLCHAIN_DIR/gcc" ]; then
    echo "    تحميل clang و gcc..."
    cd "$TOOLCHAIN_DIR"
    wget -q --show-progress https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/clang-r450784e.tar.gz
    mkdir clang && cd clang && tar -xf ../clang-r450784e.tar.gz && cd ..
    wget -q --show-progress https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    tar -xf arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    mv arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu gcc
    cd "$KERNEL_ROOT"
    echo -e "${GREEN}[✓] toolchains جاهزة${NC}"
fi

# ========== إعداد متغيرات البناء ==========
export ARCH=arm64
export SUBARCH=arm64
export PATH="$TOOLCHAIN_DIR/clang/bin:$PATH"
export PATH="$TOOLCHAIN_DIR/gcc/bin:$PATH"
export CROSS_COMPILE=aarch64-linux-android-
export CLANG_TRIPLE=aarch64-linux-gnu-
export CC=clang
export LD=ld.lld
export LLVM=1
export LLVM_IAS=1
export TARGET_SOC="s5e8835"
export PLATFORM_VERSION="15"
export ANDROID_MAJOR_VERSION="v"

# أعلام Clang لتجنب أخطاء تعريفات سامسونج
export KBUILD_CFLAGS="$KBUILD_CFLAGS -Wno-typedef-redefinition -Wno-gnu-variable-sized-type-not-at-end"
export KBUILD_CFLAGS_MODULE="$KBUILD_CFLAGS_MODULE -Wno-typedef-redefinition -Wno-gnu-variable-sized-type-not-at-end"

# مجلد الإخراج
if [ "$USE_OUT_DIR" = true ]; then
    OUT_DIR="$KERNEL_ROOT/out"
    mkdir -p "$OUT_DIR"
    MAKE_OUT="O=$OUT_DIR"
else
    MAKE_OUT=""
    echo -e "${YELLOW}[!] البناء بدون out (لتوافق Exynos)${NC}"
fi

BUILD_DIR="$SCRIPT_DIR/build"
STOCK_DIR="$SCRIPT_DIR/stock"
mkdir -p "$BUILD_DIR" "$STOCK_DIR"

# ========== إنشاء custom.config ==========
echo "[3/9] إنشاء custom.config لتعطيل حماية سامسونج..."
CUSTOM_CONFIG="$KERNEL_ROOT/custom.config"
cat > "$CUSTOM_CONFIG" << 'EOF'
CONFIG_UH=n
CONFIG_UH_RKP=n
CONFIG_UH_LKMAUTH=n
CONFIG_UH_LKM_BLOCK=n
CONFIG_RKP_CFP_JOPP=n
CONFIG_RKP_CFP=n
CONFIG_SECURITY_DEFEX=n
CONFIG_PROCA=n
CONFIG_FIVE=n
EOF

# ========== stock_defconfig ==========
ORIG_DEFCONFIG="$KERNEL_ROOT/arch/arm64/configs/s5e8835-a35xjvxx_defconfig"
if [ -f "$ORIG_DEFCONFIG" ] && [ ! -f "$KERNEL_ROOT/stock_defconfig" ]; then
    cp "$ORIG_DEFCONFIG" "$KERNEL_ROOT/stock_defconfig"
    echo -e "${GREEN}[✓] stock_defconfig تم إنشاؤه${NC}"
fi

# ========== جلب KernelSU ==========
echo "[4/9] جلب KernelSU..."
cd "$KERNEL_ROOT"
if [ -d "KernelSU" ]; then
    cd KernelSU && git pull && cd ..
else
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
fi

# ========== تجهيز defconfigات ==========
DEFCONFIG_LIST="s5e8835-a35xjvxx_defconfig"
for cfg in common.config ksu.config custom.config; do
    if [ -f "$KERNEL_ROOT/arch/arm64/configs/$cfg" ]; then
        DEFCONFIG_LIST="$DEFCONFIG_LIST $cfg"
    fi
done

# ========== تنظيف ==========
if [ "$CLEAN_BUILD" = true ]; then
    echo "[5/9] تنظيف البناء السابق..."
    if [ "$USE_OUT_DIR" = true ]; then
        rm -rf "$OUT_DIR"
    else
        make ARCH=arm64 clean
    fi
fi

# ========== تجهيز .config ==========
echo "[6/9] تجهيز .config باستخدام: $DEFCONFIG_LIST"
make $MAKE_OUT ARCH=arm64 $DEFCONFIG_LIST

if [ -f "$CUSTOM_CONFIG" ]; then
    scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "$OUT_DIR/.config" "$CUSTOM_CONFIG" 2>/dev/null || \
    scripts/kconfig/merge_config.sh -m "$OUT_DIR/.config" "$CUSTOM_CONFIG"
fi

scripts/config --file "$OUT_DIR/.config" -d CONFIG_MODULE_SIG
scripts/config --file "$OUT_DIR/.config" -d CONFIG_MODULE_SIG_FORCE
scripts/config --file "$OUT_DIR/.config" -d CONFIG_SYSTEM_TRUSTED_KEYS
scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_LOCALVERSION "-KernelSU"
scripts/config --file "$OUT_DIR/.config" -d CONFIG_MODULE_SRCVERSION_ALL

# ========== menuconfig ==========
if [ "$MENUCONFIG" = true ]; then
    echo "[7/9] تشغيل menuconfig..."
    make $MAKE_OUT ARCH=arm64 menuconfig
    cp "$OUT_DIR/.config" "$CUSTOM_CONFIG"
fi

# ========== بناء الكيرنال ==========
echo "[8/9] بناء الكيرنال (قد يستغرق وقتاً)..."
make $MAKE_OUT ARCH=arm64 -j$(nproc) Image KBUILD_CFLAGS="-Wno-typedef-redefinition -Wno-gnu-variable-sized-type-not-at-end"

if [ -f "$OUT_DIR/arch/arm64/boot/Image" ]; then
    cp "$OUT_DIR/arch/arm64/boot/Image" "$BUILD_DIR/"
elif [ -f "arch/arm64/boot/Image" ]; then
    cp "arch/arm64/boot/Image" "$BUILD_DIR/"
else
    echo -e "${RED}❌ فشل البناء: لم يتم العثور على Image${NC}"
    exit 1
fi
echo -e "${GREEN}[✓] Image تم بناؤه بنجاح${NC}"

# ========== إنشاء boot.img ==========
if [ "$KERNEL_ONLY" = false ]; then
    echo "[9/9] إنشاء boot.img..."
    if [ ! -f "$STOCK_DIR/boot.img" ]; then
        echo -e "${RED}❌ ملف boot.img غير موجود في مجلد stock/${NC}"
        exit 1
    fi
    cd "$BUILD_DIR"
    cp "$STOCK_DIR/boot.img" .
    magiskboot unpack boot.img
    rm -f kernel
    cp Image kernel
    magiskboot repack boot.img
    mv new-boot.img boot-ksu.img
    tar -cvf boot-ksu.tar boot-ksu.img
    rm -f boot.img kernel Image
    echo -e "${GREEN}[✓] boot-ksu.img و boot-ksu.tar تم إنشاؤهما في $BUILD_DIR${NC}"
else
    echo -e "${GREEN}[✓] انتهى البناء (Image فقط)${NC}"
fi

echo -e "${GREEN}=========================================="
echo "✅ اكتمل! يمكنك فلاش boot-ksu.img عبر Odin"
echo "⚠️  تذكر عمل نسخة احتياطية للأقسام الأصلية${NC}"
