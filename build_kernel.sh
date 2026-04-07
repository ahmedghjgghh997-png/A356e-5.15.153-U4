#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380)
# (تم التعديل لتجاوز أخطاء التجميع في مجلد drivers)
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

log() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# ========================
# 1. إدخال الروابط
# ========================
echo -e "${GREEN}=== المرحلة 0: إدخال الروابط ===${NC}"
read -p "أدخل رابط سورس النواة (مباشر، Google Drive، أو git): " KERNEL_URL
read -p "أدخل رابط boot.img الأصلي (اختياري، اتركه فارغاً): " BOOT_URL
[ -z "$KERNEL_URL" ] && error "لا يمكن المتابعة بدون رابط سورس النواة."
log "رابط السورس: $KERNEL_URL"
[ -n "$BOOT_URL" ] && log "رابط boot.img: $BOOT_URL"

# ========================
# 2. تثبيت التبعيات الأساسية
# ========================
echo -e "${GREEN}=== المرحلة 1: تثبيت التبعيات ===${NC}"
if [ ! -f "$HOME/.kernel_deps_installed" ]; then
    if command -v apt &> /dev/null; then
        sudo apt update
        sudo apt install -y bc bison build-essential ccache curl device-tree-compiler \
            flex g++-multilib gcc-multilib git gnupg gperf imagemagick libc6-dev-i386 \
            libelf-dev liblz4-tool libncurses-dev libsdl1.2-dev libssl-dev \
            libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc \
            zip zlib1g-dev dwarves pahole libarchive-tools zstd kmod erofs-utils \
            unzip xz-utils python3-pip clang-18 lld-18 libyaml-dev cpio tofrodos python3-markdown
        pip install gdown
        touch "$HOME/.kernel_deps_installed"
    elif command -v dnf &> /dev/null; then
        sudo dnf group install -y "c-development" "development-tools"
        sudo dnf install -y git dtc lz4 xz zlib-devel java-17-openjdk-devel python3 \
            p7zip p7zip-plugins android-tools erofs-utils java-latest-openjdk-devel \
            ncurses-devel libX11-devel readline-devel mesa-libGL-devel python3-markdown \
            libxml2 libxslt dos2unix kmod openssl elfutils-libelf-devel dwarves \
            openssl-devel libarchive zstd rsync clang lld
        pip3 install gdown
        touch "$HOME/.kernel_deps_installed"
    else
        error "نظام غير مدعوم. قم بتثبيت التبعيات يدويًا."
    fi
else
    log "التبعيات مثبتة مسبقًا."
fi

# ========================
# 3. تحميل سلاسل الأدوات
# ========================
echo -e "${GREEN}=== المرحلة 2: تحميل سلاسل الأدوات ===${NC}"
mkdir -p "$TOOLCHAINS_DIR"

if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    log "تحميل clang-r450784e..."
    cd "$TOOLCHAINS_DIR"
    wget -q https://android.googlesource.com/platform//prebuilts/clang/host/linux-x86/+archive/722c840a8e4d58b5ebdab62ce78eacdafd301208/clang-r450784e.tar.gz
    mkdir clang-r450784e && tar -xf clang-r450784e.tar.gz -C clang-r450784e
    rm clang-r450784e.tar.gz
    cd - >/dev/null
fi

if [ ! -d "$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2" ]; then
    log "تحميل arm-gnu-toolchain-14.2..."
    cd "$TOOLCHAINS_DIR"
    wget -q https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    tar -xf arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    mv arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu arm-gnu-toolchain-14.2
    rm arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    cd - >/dev/null
fi

export PATH="$TOOLCHAINS_DIR/clang-r450784e/bin:$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2/bin:$PATH"
export CROSS_COMPILE=aarch64-none-linux-gnu-
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-

# ========================
# 4. تحميل السورس وفك الضغط
# ========================
echo -e "${GREEN}=== المرحلة 3: تحميل سورس النواة ===${NC}"
rm -rf "$KERNEL_ROOT"
mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"

download_google_drive() {
    local URL="$1" OUTPUT="$2"
    local FILE_ID=$(echo "$URL" | grep -oP '(?<=/d/)[a-zA-Z0-9_-]+' | head -1)
    [ -z "$FILE_ID" ] && FILE_ID=$(echo "$URL" | grep -oP 'id=[a-zA-Z0-9_-]+' | cut -d= -f2)
    gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$OUTPUT"
}

TEMP_FILE="source_download"
if [[ "$KERNEL_URL" == *drive.google.com* ]]; then
    download_google_drive "$KERNEL_URL" "$TEMP_FILE"
elif [[ "$KERNEL_URL" == *.git ]]; then
    git clone --depth=1 "$KERNEL_URL" .
    touch .skip_extract
else
    curl -L -o "$TEMP_FILE" "$KERNEL_URL"
fi

if [ ! -f .skip_extract ]; then
    MIME=$(file -b --mime-type "$TEMP_FILE")
    case "$MIME" in
        application/zip) unzip -q "$TEMP_FILE" -d temp && mv temp/*/* ./ 2>/dev/null || mv temp/* ./; rm -rf temp ;;
        application/gzip|application/x-gzip) tar -xzf "$TEMP_FILE" --strip-components=1 ;;
        application/x-xz) tar -xJf "$TEMP_FILE" --strip-components=1 ;;
        *) error "نوع الملف غير معروف: $MIME" ;;
    esac
    rm -f "$TEMP_FILE"
fi

if [ -f "Kernel.tar.gz" ]; then
    log "فك ضغط Kernel.tar.gz (خاص بسامسونج)"
    tar -xzf Kernel.tar.gz && rm Kernel.tar.gz
fi

[ -f "Makefile" ] || error "Makefile غير موجود. فك الضغط فشل."

# إزالة قواعد التعامل مع التحذيرات كأخطاء من Makefile لتجنب توقف البناء
log "إزالة -Werror من Makefile لتجاوز التحذيرات..."
sed -i 's/-Werror//g' Makefile

# ========================
# 5. إعدادات إضافية
# ========================
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=14
export ANDROID_MAJOR_VERSION=u

# إزالة GCC wrapper
for opt in REAL_CC CFP_CC wrapper; do
    grep -q "$opt" Makefile && sed -i "/$opt/d" Makefile
done

# ========================
# 6. defconfig
# ========================
DEFCONFIG="s5e8835-a35xjvxx_defconfig"
log "استخدام defconfig: $DEFCONFIG"
make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- $DEFCONFIG
[ ! -f "arch/arm64/configs/stock_defconfig" ] && cp "arch/arm64/configs/$DEFCONFIG" "arch/arm64/configs/stock_defconfig"

# ========================
# 7. menuconfig اختياري
# ========================
read -p "فتح menuconfig لتعديل الإعدادات؟ (y/n): " MENU_CHOICE
if [[ "$MENU_CHOICE" =~ ^[Yy]$ ]]; then
    make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- menuconfig
fi

# ========================
# 8. إعدادات الكيرنل (KPROBES) 
# ========================
# ملاحظة: تم إيقاف تعطيل حمايات سامسونج (DEFEX و RKP) مؤقتاً لأن إزالتها من هنا فقط 
# تسبب خطأ تجميع في مجلد drivers. إذا أردت تعطيلها، يجب توفير باتشات C معدلة مسبقاً.

if [ -f "scripts/config" ]; then
    # تفعيل الكيه بروبز المهم للروت وتعديلات النواة
    scripts/config --file ".config" -e CONFIG_KPROBES -e CONFIG_HAVE_KPROBES -e CONFIG_KPROBE_EVENTS
    scripts/config --file ".config" --disable CONFIG_MODULE_SIG_FORCE
else
    sed -i 's/CONFIG_MODULE_SIG_FORCE=y/# CONFIG_MODULE_SIG_FORCE is not set/g' .config
    echo -e "CONFIG_KPROBES=y\nCONFIG_HAVE_KPROBES=y\nCONFIG_KPROBE_EVENTS=y" >> .config
fi

# ========================
# 9. تطبيق الباتشات (اختياري)
# ========================
if [ -d "../patches" ]; then
    for patch in ../patches/*.patch; do
        [ -f "$patch" ] && git apply --check "$patch" && git apply "$patch" || warn "فشل تطبيق $patch"
    done
fi

# ========================
# 10. بناء Image
# ========================
echo -e "${GREEN}=== بناء النواة ===${NC}"
# إضافة KCFLAGS="-Wno-error" لتجاهل تحذيرات المترجم الحديث وعدم التوقف
make -j$(nproc) ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- KCFLAGS="-Wno-error" Image 2>&1 | tee "$LOG_FILE"

if [ ! -f "arch/arm64/boot/Image" ]; then
    error "فشل التجميع. راجع $LOG_FILE لمعرفة السبب الفعلي."
else
    log "تم بناء Image بنجاح! مسار الملف: arch/arm64/boot/Image"
fi
