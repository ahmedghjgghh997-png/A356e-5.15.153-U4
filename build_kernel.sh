#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380) - نسخة Khalifa المحدثة
# مطابق للدليل: ravindu644/Android-Kernel-Tutorials
# تم إضافة: KernelSU + حلول مشاكل Drivers + دعم DTBs
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

export ARCH=arm64
export KERNEL_ROOT="$(pwd)/kernel-source"
export TOOLCHAINS_DIR="$HOME/toolchains"
export BUILD_DIR="$KERNEL_ROOT/build"
export LOG_FILE="$PWD/build.log"
# تعريف اسمك كصانع للنواة
export KBUILD_BUILD_USER="Khalifa"

log() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# ========================
# 1. إدخال الروابط
# ========================
if [ -n "$GITHUB_ACTIONS" ]; then
    KERNEL_URL="$INPUT_KERNEL_URL"
    BOOT_URL="$INPUT_BOOT_URL"
else
    echo -e "${GREEN}=== المرحلة 0: إدخال الروابط ===${NC}"
    read -p "أدخل رابط سورس النواة (مباشر، Google Drive، أو git): " KERNEL_URL
    read -p "أدخل رابط boot.img الأصلي (اختياري): " BOOT_URL
fi
[ -z "$KERNEL_URL" ] && error "لا يمكن المتابعة بدون رابط سورس النواة."

# ========================
# 2. تثبيت التبعيات (تصحيح gdown)
# ========================
log "تثبيت التبعيات..."
if [ ! -f "$HOME/.kernel_deps_installed" ]; then
    sudo apt update
    sudo apt install -y bc bison build-essential ccache curl device-tree-compiler \
        flex git libelf-dev libssl-dev lz4 python3 python3-pip unzip zip zstd wget
    pip3 install gdown --quiet
    touch "$HOME/.kernel_deps_installed"
fi

# ========================
# 3. تحميل سلاسل الأدوات (Clang r450784e)
# ========================
log "تحضير سلاسل الأدوات..."
mkdir -p "$TOOLCHAINS_DIR"
if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    cd "$TOOLCHAINS_DIR"
    wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/722c840a8e4d58b5ebdab62ce78eacdafd301208/clang-r450784e.tar.gz
    mkdir clang-r450784e && tar -xf clang-r450784e.tar.gz -C clang-r450784e
    rm clang-r450784e.tar.gz
    cd - >/dev/null
fi

# إعداد المسارات (استخدام aarch64-linux-gnu- لضمان التوافق)
export PATH="$TOOLCHAINS_DIR/clang-r450784e/bin:$PATH"
export CROSS_COMPILE=aarch64-linux-gnu-
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-

# ========================
# 4. تحميل السورس (إصلاح خطأ التحميل من Drive)
# ========================
log "تحميل سورس النواة..."
rm -rf "$KERNEL_ROOT" && mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"

if [[ "$KERNEL_URL" == *drive.google.com* ]]; then
    FILE_ID=$(echo "$KERNEL_URL" | sed -r 's/.*\/d\/([a-zA-Z0-9_-]+).*/\1/; s/.*id=([a-zA-Z0-9_-]+).*/\1/')
    gdown "$FILE_ID" -O source_zip
    unzip -q source_zip || tar -xf source_zip
elif [[ "$KERNEL_URL" == *.git ]]; then
    git clone --depth=1 "$KERNEL_URL" .
else
    curl -L -o source_archive "$KERNEL_URL"
    tar -xf source_archive --strip-components=1 || unzip source_archive
fi

# ========================
# 5. تنظيف الـ Makefile (حل Error 2 الحاسم)
# ========================
log "تنظيف Makefile من قيود سامسونج..."
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=14
export ANDROID_MAJOR_VERSION=u

sed -i 's/gcc-wrapper.py//g' Makefile
sed -i 's/clang-wrapper.py//g' Makefile
for opt in REAL_CC CFP_CC wrapper; do
    sed -i "/$opt/d" Makefile
done

# ========================
# 6. حقن كود KernelSU
# ========================
log "دمج KernelSU..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# ========================
# 7. بناء الـ Config وتعطيل الحماية
# ========================
DEFCONFIG="s5e8835-a35xjvxx_defconfig"
log "إعداد الـ Config وتعديل الحماية..."
make ARCH=arm64 CC=clang $DEFCONFIG

scripts/config --file ".config" \
    -e CONFIG_KSU -e CONFIG_OVERLAY_FS -e CONFIG_KPROBES -e CONFIG_KPROBE_EVENTS \
    --set-str CONFIG_LOCALVERSION "-Khalifa-KSU" \
    -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE

# ========================
# 10. بناء النواة (إضافة dtbs الحتمية)
# ========================
log "بدء التجميع (Image + dtbs)..."
make -j$(nproc) ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- Image dtbs 2>&1 | tee "$LOG_FILE"

# ========================
# 11. التحقق وجمع المخرجات
# ========================
if [ -f "arch/arm64/boot/Image" ]; then
    log "تم البناء بنجاح!"
    mkdir -p "$BUILD_DIR"
    cp arch/arm64/boot/Image "$BUILD_DIR/"
    # نسخ ملفات الـ dtb لأن الـ Exynos بيعتمد عليها تماماً
    find arch/arm64/boot/dts/samsung/ -name "*.dtb" -exec cp {} "$BUILD_DIR/" \;
    log "الملفات جاهزة في $BUILD_DIR"
else
    error "لم يتم إنتاج ملف Image. تفقد build.log"
fi
