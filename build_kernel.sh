#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380) - نسخة Khalifa
# مدمج به: KernelSU + تخطي حماية سامسونج + دعم Google Drive
# ============================================================

set -e

# الألوان
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 1. تعريف المسارات
export ARCH=arm64
export KERNEL_ROOT="$(pwd)/kernel-source"
export TOOLCHAINS_DIR="$HOME/toolchains"
export BUILD_DIR="$KERNEL_ROOT/build"
export KBUILD_BUILD_USER="Khalifa"
export KBUILD_BUILD_HOST="Android-Build"

# 2. الحصول على الروابط (من GitHub Actions)
if [ -n "$GITHUB_ACTIONS" ]; then
    KERNEL_URL="$INPUT_KERNEL_URL"
    BOOT_URL="$INPUT_BOOT_URL"
else
    read -p "رابط السورس: " KERNEL_URL
    read -p "رابط boot.img الأصلي (اختياري): " BOOT_URL
fi

# 3. تثبيت التبعيات الضرورية
log "تثبيت الأدوات والتبعيات..."
sudo apt update && sudo apt install -y bc bison build-essential curl git git-lfs \
    libelf-dev libssl-dev lz4 python3 python3-pip zip zstd clang lld wget unzip gdown

# 4. تحضير سلاسل الأدوات (Clang r450784e - اللي كانت شغالة معاك)
log "تحضير سلاسل الأدوات..."
mkdir -p "$TOOLCHAINS_DIR"
if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    cd "$TOOLCHAINS_DIR"
    wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/722c840a8e4d58b5ebdab62ce78eacdafd301208/clang-r450784e.tar.gz
    mkdir clang-r450784e && tar -xf clang-r450784e.tar.gz -C clang-r450784e
    rm clang-r450784e.tar.gz
    cd - >/dev/null
fi

export PATH="$TOOLCHAINS_DIR/clang-r450784e/bin:$PATH"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-

# 5. تحميل سورس النواة (دعم ذكي لجوجل درايف)
log "جاري تحميل سورس النواة..."
rm -rf "$KERNEL_ROOT" && mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"

if [[ "$KERNEL_URL" == *drive.google.com* ]]; then
    ID=$(echo "$KERNEL_URL" | sed -r 's/.*\/d\/([a-zA-Z0-9_-]+).*/\1/; s/.*id=([a-zA-Z0-9_-]+).*/\1/')
    gdown "$ID" -O src.zip
    unzip -q src.zip || tar -xf src.zip
elif [[ "$KERNEL_URL" == *.git ]]; then
    git clone --depth=1 "$KERNEL_URL" .
else
    curl -L "$KERNEL_URL" -o src.archive
    tar -xf src.archive --strip-components=1 || unzip src.archive
fi

# 6. تنظيف الـ Makefile من الـ Wrappers (لحل Error 2 فيDrivers)
log "تنظيف Makefile من قيود سامسونج..."
sed -i 's/gcc-wrapper.py//g' Makefile
sed -i 's/clang-wrapper.py//g' Makefile
for opt in REAL_CC CFP_CC wrapper; do
    sed -i "/$opt/d" Makefile
done

# 7. حقن كود KernelSU (الروت)
log "دمج كود KernelSU في النواة..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# 8. تجهيز الـ Config وتخصيصه
log "تجهيز الإعدادات وتعطيل الحماية..."
export TARGET_SOC=s5e8835
make ARCH=arm64 CC=clang s5e8835-a35xjvxx_defconfig

# تفعيل الروت + تعطيل حماية سامسونج (RKP, KNOX, PROCA)
scripts/config --file ".config" \
    -e CONFIG_KSU \
    -e CONFIG_OVERLAY_FS \
    -e CONFIG_KPROBES \
    -e CONFIG_KPROBE_EVENTS \
    --set-str CONFIG_LOCALVERSION "-Khalifa-$(date +%Y%m%d)" \
    -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
    -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE

# 9. عملية البناء الشاملة (Image + dtbs)
log "بدء التجميع النهائي (هذه العملية تستغرق وقتاً)..."
make -j$(nproc) ARCH=arm64 CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    Image dtbs

# 10. التحقق وجمع المخرجات
if [ -f "arch/arm64/boot/Image" ]; then
    log "مبروك! تم بناء النواة بنجاح."
    mkdir -p "$BUILD_DIR"
    cp arch/arm64/boot/Image "$BUILD_DIR/"
    # نسخ ملفات الـ DTB لأنها مهمة جداً لـ Exynos
    find arch/arm64/boot/dts/samsung/ -name "*.dtb" -exec cp {} "$BUILD_DIR/" \;
else
    error "فشل التجميع. يرجى مراجعة سجلات البناء."
fi

# 11. دمج النواة في boot.img (إذا توفر الرابط)
if [ -n "$BOOT_URL" ]; then
    log "جاري إنشاء boot.img المروت..."
    cd "$BUILD_DIR"
    if [[ "$BOOT_URL" == *drive.google.com* ]]; then
        ID_BOOT=$(echo "$BOOT_URL" | sed -r 's/.*\/d\/([a-zA-Z0-9_-]+).*/\1/; s/.*id=([a-zA-Z0-9_-]+).*/\1/')
        gdown "$ID_BOOT" -O stock_boot.img
    else
        curl -L "$BOOT_URL" -o stock_boot.img
    fi
    
    # تحميل magiskboot للـ Repack
    wget -q https://github.com/magisk-modules-alt-repo/magiskboot_x86_64/raw/main/magiskboot
    chmod +x magiskboot
    
    ./magiskboot unpack stock_boot.img
    mv Image kernel
    ./magiskboot repack stock_boot.img rooted_boot.img
    log "تم إنشاء الملف النهائي: rooted_boot.img"
fi

log "انتهت العملية. الملفات موجودة في مجلد: $BUILD_DIR"
