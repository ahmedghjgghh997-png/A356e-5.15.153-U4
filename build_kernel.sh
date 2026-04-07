#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380)
# تم إضافة دمج KernelSU وإصلاحات GitHub Actions
# ============================================================

# إيقاف التشغيل عند أول خطأ (مع التأكد من اكتشاف أخطاء Make)
set -eo pipefail

# الألوان للطباعة
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ========================
# متغيرات عامة
# ========================
export ARCH=arm64
export KERNEL_ROOT="$(pwd)/kernel-source"
export TOOLCHAINS_DIR="$HOME/toolchains"
export BUILD_DIR="$KERNEL_ROOT/build"
export LOG_FILE="$PWD/build.log"

# ========================
# دوال مساعدة
# ========================
log() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# التحقق من وجود أمر
check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "$1 غير موجود. قم بتثبيته أولاً."
    fi
}

# ========================
# 1. إدخال الروابط من المستخدم (أو من GitHub Actions)
# ========================
echo -e "${GREEN}=== المرحلة 0: إدخال الروابط ===${NC}"
# سحب المتغيرات من بيئة العمل لو كانت موجودة (مهم لـ GitHub Actions)
KERNEL_URL=${KERNEL_URL_ENV:-""}
BOOT_URL=${BOOT_URL_ENV:-""}
MENU_CHOICE=${MENU_CHOICE_ENV:-""}
AK3_CHOICE=${AK3_CHOICE_ENV:-""}

if [ -z "$KERNEL_URL" ]; then
    read -p "أدخل رابط سورس النواة (مباشر، Google Drive، أو git): " KERNEL_URL
    read -p "أدخل رابط boot.img الأصلي (اختياري، اتركه فارغاً إذا لم يتوفر): " BOOT_URL
fi

if [ -z "$KERNEL_URL" ]; then
    error "لا يمكن المتابعة بدون رابط سورس النواة."
fi

log "تم استلام الرابط: $KERNEL_URL"
[ -n "$BOOT_URL" ] && log "رابط boot.img: $BOOT_URL"

# ========================
# 2. تثبيت التبعيات الأساسية (مرة واحدة)
# ========================
echo -e "${GREEN}=== المرحلة 1: تثبيت التبعيات الأساسية ===${NC}"
if [ ! -f "$HOME/.kernel_deps_installed" ]; then
    if command -v apt &> /dev/null; then
        log "نظام Ubuntu/Debian detected. جاري تثبيت التبعيات..."
        sudo apt update
        sudo apt install -y bc bison build-essential ccache curl device-tree-compiler \
            flex g++-multilib gcc-multilib git gnupg gperf imagemagick libc6-dev-i386 \
            libelf-dev liblz4-tool libncurses-dev libsdl1.2-dev libssl-dev \
            libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc \
            zip zlib1g-dev dwarves pahole libarchive-tools zstd kmod erofs-utils \
            unzip xz-utils python3-pip clang-18 lld-18 libyaml-dev cpio tofrodos python3-markdown
        # إضافة break-system-packages لإصلاح مشكلة Ubuntu 24
        pip install gdown --break-system-packages 2>/dev/null || pip3 install gdown
        touch "$HOME/.kernel_deps_installed"
    elif command -v dnf &> /dev/null; then
        log "نظام Fedora/RHEL detected. جاري تثبيت التبعيات..."
        sudo dnf group install -y "c-development" "development-tools"
        sudo dnf install -y git dtc lz4 xz zlib-devel java-17-openjdk-devel python3 \
            p7zip p7zip-plugins android-tools erofs-utils java-latest-openjdk-devel \
            ncurses-devel libX11-devel readline-devel mesa-libGL-devel python3-markdown \
            libxml2 libxslt dos2unix kmod openssl elfutils-libelf-devel dwarves \
            openssl-devel libarchive zstd rsync clang lld
        pip3 install gdown --break-system-packages 2>/dev/null || pip3 install gdown
        touch "$HOME/.kernel_deps_installed"
    else
        error "نظام غير مدعوم. يرجى تثبيت التبعيات يدويًا حسب الدليل."
    fi
else
    log "التبعيات مثبتة مسبقًا. تخطي..."
fi

# ========================
# 3. تحميل سلاسل الأدوات (Toolchains)
# ========================
echo -e "${GREEN}=== المرحلة 2: تحميل سلاسل الأدوات ===${NC}"
mkdir -p "$TOOLCHAINS_DIR"

# Clang
if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    log "تحميل clang-r450784e..."
    cd "$TOOLCHAINS_DIR"
    wget -q https://android.googlesource.com/platform//prebuilts/clang/host/linux-x86/+archive/722c840a8e4d58b5ebdab62ce78eacdafd301208/clang-r450784e.tar.gz
    mkdir clang-r450784e && tar -xf clang-r450784e.tar.gz -C clang-r450784e
    rm clang-r450784e.tar.gz
    cd - >/dev/null
else
    log "clang-r450784e موجود مسبقًا. تخطي..."
fi

# GCC ARM64
if [ ! -d "$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2" ]; then
    log "تحميل arm-gnu-toolchain-14.2..."
    cd "$TOOLCHAINS_DIR"
    wget -q https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    tar -xf arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    mv arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu arm-gnu-toolchain-14.2
    rm arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    cd - >/dev/null
else
    log "arm-gnu-toolchain-14.2 موجود مسبقًا. تخطي..."
fi

export PATH="$TOOLCHAINS_DIR/clang-r450784e/bin:$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2/bin:$PATH"
export CROSS_COMPILE=aarch64-none-linux-gnu-
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-

# ========================
# 4. تحميل سورس النواة وفك ضغطه
# ========================
echo -e "${GREEN}=== المرحلة 3: تحميل سورس النواة ===${NC}"
rm -rf "$KERNEL_ROOT"
mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"

download_google_drive() {
    local URL="$1"
    local OUTPUT="$2"
    local FILE_ID=$(echo "$URL" | grep -oP '(?<=/d/)[a-zA-Z0-9_-]+' | head -1)
    if [ -z "$FILE_ID" ]; then
        FILE_ID=$(echo "$URL" | grep -oP 'id=[a-zA-Z0-9_-]+' | cut -d= -f2)
    fi
    if [ -z "$FILE_ID" ]; then
        error "لم نتمكن من استخراج معرف الملف من رابط Google Drive."
    fi
    gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$OUTPUT"
}

TEMP_FILE="source_download"
if [[ "$KERNEL_URL" == *drive.google.com* ]]; then
    log "تحميل من Google Drive..."
    download_google_drive "$KERNEL_URL" "$TEMP_FILE"
elif [[ "$KERNEL_URL" == *.git ]]; then
    log "استنساخ من مستودع git..."
    git clone --depth=1 "$KERNEL_URL" .
    touch .skip_extract
else
    log "تحميل من رابط مباشر..."
    curl -L -o "$TEMP_FILE" "$KERNEL_URL"
fi

if [ ! -f .skip_extract ]; then
    MIME=$(file -b --mime-type "$TEMP_FILE")
    log "نوع الملف المكتشف: $MIME"
    case "$MIME" in
        application/zip)
            unzip -q "$TEMP_FILE" -d temp_extract
            mv temp_extract/*/* ./ 2>/dev/null || mv temp_extract/* ./ 2>/dev/null
            rm -rf temp_extract
            ;;
        application/gzip|application/x-gzip)
            tar -xzf "$TEMP_FILE" --strip-components=1
            ;;
        application/x-xz)
            tar -xJf "$TEMP_FILE" --strip-components=1
            ;;
        *)
            error "نوع الملف غير معروف: $MIME"
            ;;
    esac
    rm -f "$TEMP_FILE"
fi

if [ -f "Kernel.tar.gz" ]; then
    log "تم العثور على Kernel.tar.gz، جاري فك ضغطه..."
    tar -xzf Kernel.tar.gz && rm Kernel.tar.gz
fi

if [ ! -f "Makefile" ]; then
    error "لم يتم العثور على Makefile. ربما فك الضغط لم يتم بشكل صحيح."
fi

# ========================
# 5. حقن وتثبيت KernelSU
# ========================
echo -e "${GREEN}=== المرحلة 4: حقن كود KernelSU ===${NC}"
log "جاري تحميل ودمج KernelSU داخل النواة..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
log "تم دمج كود KernelSU بنجاح في السورس."

# ========================
# 6. التحضير للتجميع وتجهيز defconfig
# ========================
echo -e "${GREEN}=== المرحلة 5: التحضير وتجهيز defconfig ===${NC}"
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=14
export ANDROID_MAJOR_VERSION=u

if grep -q "REAL_CC" Makefile; then sed -i '/REAL_CC/d' Makefile; fi
if grep -q "CFP_CC" Makefile; then sed -i '/CFP_CC/d' Makefile; fi
if grep -q "wrapper" Makefile; then sed -i '/wrapper/d' Makefile; fi

DEFCONFIG="s5e8835-a35xjvxx_defconfig"
log "استخدام defconfig: $DEFCONFIG"

make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- $DEFCONFIG

if [ ! -f "arch/arm64/configs/stock_defconfig" ]; then
    cp "arch/arm64/configs/$DEFCONFIG" "arch/arm64/configs/stock_defconfig"
fi

# ========================
# 7. تخصيص النواة (menuconfig)
# ========================
echo -e "${GREEN}=== المرحلة 6: تخصيص النواة (اختياري) ===${NC}"
if [ -z "$MENU_CHOICE" ]; then
    read -p "هل تريد فتح menuconfig لتعديل الإعدادات يدويًا؟ (y/n): " MENU_CHOICE
fi

if [[ "$MENU_CHOICE" == "y" || "$MENU_CHOICE" == "Y" ]]; then
    if [ ! -t 0 ]; then
        warn "أنت تعمل في بيئة غير تفاعلية (GitHub Actions). سيتم تخطي menuconfig تجنباً لتوقف السكريبت."
    else
        make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- menuconfig
    fi
fi

# ========================
# 8. تعطيل حماية سامسونج وتفعيل KernelSU
# ========================
echo -e "${GREEN}=== المرحلة 7: تعطيل حماية سامسونج وتفعيل KSU ===${NC}"
log "تعطيل خيارات الحماية وتفعيل KernelSU..."

if [ -f "scripts/config" ]; then
    # تعطيل الحمايات بالكامل (محدثة لمنع البوت لوب)
    scripts/config --file ".config" -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
        -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE -d CONFIG_SECURITY_DSMS \
        -d CONFIG_KNOX_KAP -d CONFIG_SAMSUNG_FREECESS -d CONFIG_MODULE_SIG_FORCE
    
    # تفعيل KSU ومتطلباته
    scripts/config --file ".config" -e CONFIG_KPROBES -e CONFIG_HAVE_KPROBES -e CONFIG_KPROBE_EVENTS -e CONFIG_KSU
else
    warn "scripts/config غير موجود. سيتم استخدام sed."
    sed -i 's/CONFIG_UH=y/# CONFIG_UH is not set/g' .config
    sed -i 's/CONFIG_SECURITY_DEFEX=y/# CONFIG_SECURITY_DEFEX is not set/g' .config
    # تفعيل ksu يدويا
    echo "CONFIG_KPROBES=y" >> .config
    echo "CONFIG_HAVE_KPROBES=y" >> .config
    echo "CONFIG_KPROBE_EVENTS=y" >> .config
    echo "CONFIG_KSU=y" >> .config
fi

# ========================
# 9. تطبيق الباتشات الإضافية (من كودك الأصلي)
# ========================
if [ -d "$PWD/patches" ]; then
    echo -e "${GREEN}=== المرحلة 8: تطبيق الباتشات الإضافية ===${NC}"
    for patch in patches/*.patch; do
        if [ -f "$patch" ]; then
            log "تطبيق $patch"
            git apply --check "$patch" && git apply "$patch" || warn "فشل تطبيق $patch (قد يكون مطبقًا مسبقًا)"
        fi
    done
fi

# ========================
# 10. ترجمة النواة (بناء Image)
# ========================
echo -e "${GREEN}=== المرحلة 9: ترجمة النواة ===${NC}"
log "بدء التجميع..."
make -j$(nproc) ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- Image 2>&1 | tee "$LOG_FILE"

if [ ! -f "arch/arm64/boot/Image" ]; then
    error "لم يتم العثور على Image بعد التجميع. راجع $LOG_FILE"
fi

mkdir -p "$BUILD_DIR"
cp arch/arm64/boot/Image "$BUILD_DIR/"
log "تم إنشاء Image في: $BUILD_DIR/Image"

# ========================
# 11. تحميل boot.img الأصلي (من كودك الأصلي)
# ========================
if [ -n "$BOOT_URL" ]; then
    echo -e "${GREEN}=== المرحلة 10: تحضير boot.img ===${NC}"
    log "تحميل boot.img من الرابط..."
    mkdir -p "$KERNEL_ROOT/stock_boot"
    if [[ "$BOOT_URL" == *drive.google.com* ]]; then
        download_google_drive "$BOOT_URL" "$KERNEL_ROOT/stock_boot/boot.img"
    else
        curl -L -o "$KERNEL_ROOT/stock_boot/boot.img" "$BOOT_URL"
    fi
    if [ ! -f "$KERNEL_ROOT/stock_boot/boot.img" ]; then
        error "فشل تحميل boot.img"
    fi

    if ! command -v magiskboot &> /dev/null; then
        log "تثبيت magiskboot..."
        mkdir -p tools/magisk && cd tools/magisk
        wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
        unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libmagiskboot.so' -d .
        mv libmagiskboot.so magiskboot && chmod +x magiskboot
        sudo cp magiskboot /usr/local/bin/ 2>/dev/null || cp magiskboot "$HOME/.local/bin/"
        export PATH="$HOME/.local/bin:$PATH"
        cd - >/dev/null
    fi

    log "استبدال النواة في boot.img..."
    mkdir -p boot_work
    cp "$KERNEL_ROOT/stock_boot/boot.img" boot_work/
    cd boot_work
    magiskboot unpack boot.img
    cp "$BUILD_DIR/Image" kernel
    magiskboot repack boot.img
    mv new-boot.img "$BUILD_DIR/boot.img"
    cd ..
    log "تم إنشاء boot.img بداخلها KernelSU في: $BUILD_DIR/boot.img"
fi

# ========================
# 12. إنشاء AnyKernel3.zip (من كودك الأصلي)
# ========================
echo -e "${GREEN}=== المرحلة 11: إنشاء AnyKernel3.zip (اختياري) ===${NC}"
if [ -z "$AK3_CHOICE" ]; then
    read -p "هل تريد إنشاء حزمة AnyKernel3.zip؟ (y/n): " AK3_CHOICE
fi

if [[ "$AK3_CHOICE" == "y" || "$AK3_CHOICE" == "Y" ]]; then
    if [ ! -d "AnyKernel3" ]; then
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    fi
    cp "$BUILD_DIR/Image" AnyKernel3/
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
    log "تم إنشاء AnyKernel3.zip في مجلد build/"
fi

# ========================
# النهاية
# ========================
echo -e "${GREEN}=== انتهى السكريبت بنجاح وتم دمج KernelSU ===${NC}"
echo "الملفات الناتجة موجودة في: $BUILD_DIR"
ls -la "$BUILD_DIR"
