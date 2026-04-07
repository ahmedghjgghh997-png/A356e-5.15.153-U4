#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380)
# مطابق للدليل: ravindu644/Android-Kernel-Tutorials
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# متغيرات عامة
export ARCH=arm64
export KERNEL_ROOT="$(pwd)/kernel-source"
export TOOLCHAINS_DIR="$HOME/toolchains"
export BUILD_DIR="$KERNEL_ROOT/build"
export LOG_FILE="$PWD/build.log"

# ========== 1. الحصول على الروابط (من المستخدم أو من متغيرات البيئة) ==========
if [ -n "$GITHUB_ACTIONS" ]; then
    KERNEL_URL="$INPUT_KERNEL_URL"
    BOOT_URL="$INPUT_BOOT_URL"
else
    echo -e "${GREEN}=== الخطوة 1: إدخال الروابط ===${NC}"
    read -p "رابط سورس النواة (مباشر، Google Drive، git): " KERNEL_URL
    read -p "رابط boot.img الأصلي (اختياري): " BOOT_URL
fi
[ -z "$KERNEL_URL" ] && error "رابط السورس مطلوب."
log "رابط السورس: $KERNEL_URL"
[ -n "$BOOT_URL" ] && log "رابط boot.img: $BOOT_URL"

# ========== 2. تثبيت التبعيات (مرة واحدة) ==========
echo -e "${GREEN}=== الخطوة 2: تثبيت التبعيات ===${NC}"
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

# ========== 3. اختيار سلسلة الأدوات (لنواة 5.15) ==========
echo -e "${GREEN}=== الخطوة 3: تحضير سلاسل الأدوات ===${NC}"
mkdir -p "$TOOLCHAINS_DIR"

if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    log "تحميل clang-r450784e من Google..."
    cd "$TOOLCHAINS_DIR"
    wget -q https://android.googlesource.com/platform//prebuilts/clang/host/linux-x86/+archive/722c840a8e4d58b5ebdab62ce78eacdafd301208/clang-r450784e.tar.gz
    mkdir clang-r450784e && tar -xf clang-r450784e.tar.gz -C clang-r450784e
    rm clang-r450784e.tar.gz
    cd - >/dev/null
fi

if [ ! -d "$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2" ]; then
    log "تحميل ARM GNU Toolchain 14.2..."
    cd "$TOOLCHAINS_DIR"
    wget -q https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    tar -xf arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz
    mv arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu arm-gnu-toolchain-14.2
    rm *.tar.xz
    cd - >/dev/null
fi

export PATH="$TOOLCHAINS_DIR/clang-r450784e/bin:$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2/bin:$PATH"
export CROSS_COMPILE=aarch64-none-linux-gnu-
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-
log "سلاسل الأدوات جاهزة."

# ========== 4. تحميل سورس النواة وفك ضغطه ==========
echo -e "${GREEN}=== الخطوة 4: تحميل سورس النواة ===${NC}"
rm -rf "$KERNEL_ROOT"
mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"

download_google_drive() {
    local URL="$1" OUTPUT="$2"
    local ID=$(echo "$URL" | grep -oP '(?<=/d/)[a-zA-Z0-9_-]+' | head -1)
    [ -z "$ID" ] && ID=$(echo "$URL" | grep -oP 'id=[a-zA-Z0-9_-]+' | cut -d= -f2)
    gdown "https://drive.google.com/uc?id=${ID}" -O "$OUTPUT"
}

TEMP="source.download"
if [[ "$KERNEL_URL" == *drive.google.com* ]]; then
    download_google_drive "$KERNEL_URL" "$TEMP"
elif [[ "$KERNEL_URL" == *.git ]]; then
    git clone --depth=1 "$KERNEL_URL" .
    touch .skip_extract
else
    curl -L -o "$TEMP" "$KERNEL_URL"
fi

if [ ! -f .skip_extract ]; then
    MIME=$(file -b --mime-type "$TEMP")
    case "$MIME" in
        application/zip) unzip -q "$TEMP" -d temp && mv temp/*/* ./ 2>/dev/null || mv temp/* ./; rm -rf temp ;;
        application/gzip|application/x-gzip) tar -xzf "$TEMP" --strip-components=1 ;;
        application/x-xz) tar -xJf "$TEMP" --strip-components=1 ;;
        *) error "نوع الملف غير معروف: $MIME" ;;
    esac
    rm -f "$TEMP"
fi

if [ -f "Kernel.tar.gz" ]; then
    log "فك ضغط Kernel.tar.gz (خاص بسامسونج)"
    tar -xzf Kernel.tar.gz && rm Kernel.tar.gz
fi

[ -f "Makefile" ] || error "Makefile غير موجود. فك الضغط فشل."
log "تم تحضير سورس النواة في $KERNEL_ROOT"

# ========== 5. التحضير للتجميع (متغيرات سامسونج وإزالة الـ wrapper) ==========
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=14
export ANDROID_MAJOR_VERSION=u
for opt in REAL_CC CFP_CC wrapper; do
    grep -q "$opt" Makefile && sed -i "/$opt/d" Makefile
done

# ========== 6. تجهيز defconfig ==========
DEFCONFIG="s5e8835-a35xjvxx_defconfig"
log "استخدام defconfig: $DEFCONFIG"
make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- $DEFCONFIG
cp "arch/arm64/configs/$DEFCONFIG" "arch/arm64/configs/stock_defconfig" 2>/dev/null || true

# ========== 7. الطريقة الدائمة للتخصيص (custom.config) ==========
if [ -f "../custom.config" ]; then
    log "دمج custom.config (تعديلات دائمة)"
    cp ../custom.config .
    scripts/kconfig/merge_config.sh -m -O . .config custom.config
fi

# ========== 8. الطريقة المؤقتة (menuconfig) اختياري ==========
if [ -z "$GITHUB_ACTIONS" ]; then
    read -p "هل تريد فتح menuconfig لتعديل الإعدادات يدويًا؟ (y/n): " MENU_CHOICE
    if [[ "$MENU_CHOICE" =~ ^[Yy]$ ]]; then
        make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- menuconfig
    fi
else
    log "بيئة CI - تخطي menuconfig."
fi

# ========== 9. تعطيل حماية سامسونج (nuke) ==========
log "تعطيل حماية سامسونج (RKP, Knox, DEFEX, FIVE, PROCA)..."
if [ -f "scripts/config" ]; then
    scripts/config --file ".config" -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
        -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE
    scripts/config --file ".config" --disable CONFIG_MODULE_SIG_FORCE
else
    for opt in CONFIG_UH CONFIG_UH_RKP CONFIG_RKP_CFP CONFIG_SECURITY_DEFEX CONFIG_PROCA CONFIG_FIVE; do
        sed -i "s/${opt}=y/# ${opt} is not set/g" .config
    done
    sed -i 's/CONFIG_MODULE_SIG_FORCE=y/# CONFIG_MODULE_SIG_FORCE is not set/g' .config
fi

# تفعيل KPROBES (لـ KernelSU)
if [ -f "scripts/config" ]; then
    scripts/config --file ".config" -e CONFIG_KPROBES -e CONFIG_HAVE_KPROBES -e CONFIG_KPROBE_EVENTS
else
    echo -e "CONFIG_KPROBES=y\nCONFIG_HAVE_KPROBES=y\nCONFIG_KPROBE_EVENTS=y" >> .config
fi

# ========== 10. تطبيق الباتشات الإضافية ==========
if [ -d "../patches" ]; then
    log "تطبيق الباتشات من مجلد ../patches"
    for p in ../patches/*.patch; do
        [ -f "$p" ] && git apply --check "$p" && git apply "$p" || warn "فشل تطبيق $(basename $p)"
    done
fi

# ========== 11. ترجمة النواة ==========
log "بدء التجميع (make Image)..."
make -j$(nproc) ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-none-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- Image 2>&1 | tee "$LOG_FILE"

if [ ! -f "arch/arm64/boot/Image" ]; then
    echo -e "${RED}لم يتم العثور على Image.${NC}"
    echo "آخر 100 سطر من السجل:"
    tail -100 "$LOG_FILE" | grep -i "error" || tail -100 "$LOG_FILE"
    error "فشل التجميع."
fi

mkdir -p "$BUILD_DIR"
cp arch/arm64/boot/Image "$BUILD_DIR/"
log "تم إنشاء Image في $BUILD_DIR/Image"

# ========== 12. بناء boot.img موقع (إذا توفر boot.img الأصلي) ==========
if [ -n "$BOOT_URL" ]; then
    log "تحضير boot.img..."
    mkdir -p "$KERNEL_ROOT/stock_boot"
    if [[ "$BOOT_URL" == *drive.google.com* ]]; then
        download_google_drive "$BOOT_URL" "$KERNEL_ROOT/stock_boot/boot.img"
    else
        curl -L -o "$KERNEL_ROOT/stock_boot/boot.img" "$BOOT_URL"
    fi
    [ -f "$KERNEL_ROOT/stock_boot/boot.img" ] || error "فشل تحميل boot.img"

    # تثبيت magiskboot
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

    mkdir -p boot_work && cp "$KERNEL_ROOT/stock_boot/boot.img" boot_work/
    cd boot_work
    magiskboot unpack boot.img
    cp "$BUILD_DIR/Image" kernel
    magiskboot repack boot.img
    mv new-boot.img "$BUILD_DIR/boot.img"
    cd ..
    log "تم إنشاء boot.img في $BUILD_DIR/boot.img"
else
    warn "لم يتم توفير boot.img الأصلي. لن يتم إنشاء boot.img."
fi

# ========== 13. إنشاء AnyKernel3.zip (اختياري) ==========
if [ -z "$GITHUB_ACTIONS" ]; then
    read -p "هل تريد إنشاء AnyKernel3.zip للتفليش عبر TWRP؟ (y/n): " AK3_CHOICE
else
    AK3_CHOICE="n"
fi
if [[ "$AK3_CHOICE" =~ ^[Yy]$ ]]; then
    if [ ! -d "AnyKernel3" ]; then
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    fi
    cp "$BUILD_DIR/Image" AnyKernel3/
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
    log "تم إنشاء AnyKernel3.zip"
fi

echo -e "${GREEN}=== انتهى السكريبت بنجاح ===${NC}"
echo "الملفات الناتجة في: $BUILD_DIR"
ls -la "$BUILD_DIR"
