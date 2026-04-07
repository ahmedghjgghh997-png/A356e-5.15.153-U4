#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 مع KernelSU
# ============================================================

set -eo pipefail

# الألوان للطباعة
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
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

echo -e "${GREEN}=== المرحلة 0: إدخال الروابط ===${NC}"
KERNEL_URL="${KERNEL_URL_ENV}"
BOOT_URL="${BOOT_URL_ENV}"

if [ -z "$KERNEL_URL" ]; then error "رابط سورس النواة فارغ!"; fi
if [ -z "$BOOT_URL" ]; then error "رابط boot.img فارغ!"; fi

log "تم استلام رابط النواة: $KERNEL_URL"
log "تم استلام رابط البوت: $BOOT_URL"

echo -e "${GREEN}=== المرحلة 1: تثبيت التبعيات الأساسية ===${NC}"
if [ ! -f "$HOME/.kernel_deps_installed" ]; then
    sudo apt-get update -y
    sudo apt-get install -y bc bison build-essential ccache curl device-tree-compiler \
        flex g++-multilib gcc-multilib git gnupg gperf imagemagick libc6-dev-i386 \
        libelf-dev liblz4-tool libncurses-dev libsdl1.2-dev libssl-dev \
        libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc \
        zip zlib1g-dev dwarves pahole libarchive-tools zstd kmod erofs-utils \
        unzip xz-utils python3-pip clang-18 lld-18 libyaml-dev cpio tofrodos python3-markdown
    pip install gdown --break-system-packages 2>/dev/null || true
    touch "$HOME/.kernel_deps_installed"
fi

echo -e "${GREEN}=== المرحلة 2: تحميل سلاسل الأدوات ===${NC}"
mkdir -p "$TOOLCHAINS_DIR"

if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    log "تحميل clang-r450784e..."
    cd "$TOOLCHAINS_DIR"
    wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/722c840a8e4d58b5ebdab62ce78eacdafd301208/clang-r450784e.tar.gz
    mkdir -p clang-r450784e && tar -xf clang-r450784e.tar.gz -C clang-r450784e
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

echo -e "${GREEN}=== المرحلة 3: تحميل سورس النواة ===${NC}"
rm -rf "$KERNEL_ROOT" && mkdir -p "$KERNEL_ROOT" && cd "$KERNEL_ROOT"

download_google_drive() {
    local URL="$1"
    local OUTPUT="$2"
    local FILE_ID=$(echo "$URL" | grep -oP '(?<=/d/)[a-zA-Z0-9_-]+' | head -1)
    [ -z "$FILE_ID" ] && FILE_ID=$(echo "$URL" | grep -oP 'id=[a-zA-Z0-9_-]+' | cut -d= -f2)
    [ -z "$FILE_ID" ] && error "لم نتمكن من استخراج معرف الملف من جوجل درايف."
    gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$OUTPUT"
}

extract_source() {
    if ! tar -xzf source_download --strip-components=1 2>/dev/null; then
        log "الملف ليس tar.gz، جاري فك الضغط كـ zip..."
        unzip -q source_download -d temp_extract
        mv temp_extract/*/* ./ 2>/dev/null || mv temp_extract/* ./ 2>/dev/null
        rm -rf temp_extract
    fi
}

if [[ "$KERNEL_URL" == *drive.google.com* ]]; then
    download_google_drive "$KERNEL_URL" "source_download"
    extract_source
elif [[ "$KERNEL_URL" == *.git ]]; then
    git clone --depth=1 "$KERNEL_URL" .
else
    curl -L -o source_download "$KERNEL_URL"
    extract_source
fi

[ -f "Kernel.tar.gz" ] && tar -xzf Kernel.tar.gz && rm Kernel.tar.gz
[ ! -f "Makefile" ] && error "لم يتم العثور على Makefile. تأكد من صحة سورس النواة."

echo -e "${GREEN}=== المرحلة 4: حقن كود KernelSU ===${NC}"
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

echo -e "${GREEN}=== المرحلة 5: التحضير وتجهيز defconfig ===${NC}"
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t
export DTC_FLAGS="-@"
export LLVM=1
export LLVM_IAS=1

DEFCONFIG="s5e8835-a35xjvxx_defconfig"
make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-none-linux-gnu- $DEFCONFIG

if [ ! -f "arch/arm64/configs/stock_defconfig" ]; then
    cp "arch/arm64/configs/$DEFCONFIG" "arch/arm64/configs/stock_defconfig"
fi

echo -e "${GREEN}=== المرحلة 6: تعطيل حماية سامسونج وتفعيل KSU ===${NC}"
if [ -f "scripts/config" ]; then
    scripts/config --file ".config" -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
        -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE -d CONFIG_SECURITY_DSMS \
        -d CONFIG_KNOX_KAP -d CONFIG_SAMSUNG_FREECESS -d CONFIG_MODULE_SIG_FORCE \
        -d CONFIG_LTO_CLANG_THIN -d CONFIG_LTO_CLANG_FULL -e CONFIG_LTO_NONE
    
    scripts/config --file ".config" -e CONFIG_KPROBES -e CONFIG_HAVE_KPROBES -e CONFIG_KPROBE_EVENTS -e CONFIG_KSU
else
    sed -i 's/CONFIG_SECURITY_DEFEX=y/# CONFIG_SECURITY_DEFEX is not set/g' .config
    echo -e "CONFIG_KPROBES=y\nCONFIG_HAVE_KPROBES=y\nCONFIG_KPROBE_EVENTS=y\nCONFIG_KSU=y" >> .config
fi

log "جاري حفظ إعدادات النواة (olddefconfig)..."
make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-none-linux-gnu- olddefconfig

if [ -d "$PWD/patches" ]; then
    echo -e "${GREEN}=== المرحلة 7: تطبيق الباتشات الإضافية ===${NC}"
    for patch in patches/*.patch; do
        [ -f "$patch" ] && git apply "$patch" || true
    done
fi

echo -e "${GREEN}=== المرحلة 8: ترجمة النواة ===${NC}"
# --- الدرع الواقي الشامل (تمت إضافة حل مشكلة الميديا VLA و Fallthrough) ---
export SHIELD_FLAGS="-w -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-incompatible-pointer-types -Wno-pointer-sign -Wno-vla -Wno-int-conversion -Wno-return-type -Wno-implicit-fallthrough -fgnu89-inline"
export KCPPFLAGS="-Wno-error"

make -j$(nproc) ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-none-linux-gnu- KCFLAGS="$SHIELD_FLAGS" KCPPFLAGS="$KCPPFLAGS" Image

if [ ! -f "arch/arm64/boot/Image" ]; then error "فشل التجميع، لم يتم العثور على Image."; fi
mkdir -p "$BUILD_DIR" && cp arch/arm64/boot/Image "$BUILD_DIR/"

echo -e "${GREEN}=== المرحلة 9: تحضير boot.img ===${NC}"
mkdir -p "$KERNEL_ROOT/stock_boot"
if [[ "$BOOT_URL" == *drive.google.com* ]]; then
    download_google_drive "$BOOT_URL" "$KERNEL_ROOT/stock_boot/boot.img"
else
    curl -L -o "$KERNEL_ROOT/stock_boot/boot.img" "$BOOT_URL"
fi

mkdir -p "$HOME/tools/magisk" && cd "$HOME/tools/magisk"
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libmagiskboot.so' -d .
mv libmagiskboot.so magiskboot && chmod +x magiskboot
export PATH="$HOME/tools/magisk:$PATH"

cd "$KERNEL_ROOT"
mkdir -p boot_work && cp "$KERNEL_ROOT/stock_boot/boot.img" boot_work/
cd boot_work
magiskboot unpack boot.img

rm -f kernel kernel.lz4 kernel.gz kernel.bz2

cp "$BUILD_DIR/Image" kernel
magiskboot repack boot.img
mv new-boot.img "$BUILD_DIR/boot.img"

echo -e "${GREEN}=== المرحلة 10: إنشاء AnyKernel3.zip ===${NC}"
if [[ "$AK3_CHOICE_ENV" == "y" || "$AK3_CHOICE_ENV" == "Y" ]]; then
    cd "$KERNEL_ROOT"
    if [ ! -d "AnyKernel3" ]; then
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    fi
    cp "$BUILD_DIR/Image" AnyKernel3/
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
    log "تم إنشاء AnyKernel3.zip في مجلد build/"
fi

echo -e "${GREEN}=== انتهى بنجاح! تم إنشاء boot.img المدمج بـ KernelSU ===${NC}"
ls -la "$BUILD_DIR"
