#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 مع KernelSU
# (مع دعم custom.config وجميع إعدادات تعطيل الحماية)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

export ARCH=arm64
export KERNEL_ROOT="$(pwd)/kernel-source"
export BUILD_DIR="$KERNEL_ROOT/build"

# ========== 0. الروابط ==========
KERNEL_URL="${INPUT_KERNEL_URL}"
BOOT_URL="${INPUT_BOOT_URL}"
AK3_CHOICE="${AK3_CHOICE_ENV:-n}"

[ -z "$KERNEL_URL" ] && error "رابط سورس النواة فارغ!"

# ========== 1. تثبيت التبعيات ==========
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

# ========== 2. إنشاء رابط رمزي لـ ld.lld (احتياطي) ==========
if ! command -v ld.lld &> /dev/null; then
    sudo ln -sf $(which ld.lld-18) /usr/local/bin/ld.lld
    export PATH=/usr/local/bin:$PATH
fi

# ========== 3. تحميل السورس وفك الضغط ==========
rm -rf "$KERNEL_ROOT" && mkdir -p "$KERNEL_ROOT" && cd "$KERNEL_ROOT"

download_google_drive() {
    local URL="$1" OUTPUT="$2"
    local ID=$(echo "$URL" | grep -oP '(?<=/d/)[a-zA-Z0-9_-]+' | head -1)
    [ -z "$ID" ] && ID=$(echo "$URL" | grep -oP 'id=[a-zA-Z0-9_-]+' | cut -d= -f2)
    gdown "https://drive.google.com/uc?id=${ID}" -O "$OUTPUT"
}

if [[ "$KERNEL_URL" == *drive.google.com* ]]; then
    download_google_drive "$KERNEL_URL" source.download
elif [[ "$KERNEL_URL" == *.git ]]; then
    git clone --depth=1 "$KERNEL_URL" .
else
    curl -L -o source.download "$KERNEL_URL"
fi

if [ -f source.download ]; then
    if tar -xzf source.download --strip-components=1 2>/dev/null; then
        rm source.download
    else
        unzip -q source.download -d temp && mv temp/*/* ./ 2>/dev/null || mv temp/* ./; rm -rf temp source.download
    fi
fi
[ -f "Kernel.tar.gz" ] && tar -xzf Kernel.tar.gz && rm Kernel.tar.gz
[ ! -f "Makefile" ] && error "Makefile غير موجود. تأكد من صحة سورس النواة."

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

# ========== دمج custom.config (إذا كان موجودًا) ==========
if [ -f "../custom.config" ]; then
    echo -e "${GREEN}=== دمج custom.config ===${NC}"
    cp ../custom.config .
    scripts/kconfig/merge_config.sh -m -O . .config custom.config
    make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-none-linux-gnu- olddefconfig
fi

echo -e "${GREEN}=== المرحلة 6: تعطيل حماية سامسونج وتفعيل KSU ===${NC}"
if [ -f "scripts/config" ]; then
    scripts/config --file ".config" -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
        -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE -d CONFIG_SECURITY_DSMS \
        -d CONFIG_KNOX_KAP -d CONFIG_SAMSUNG_FREECESS -d CONFIG_MODULE_SIG_FORCE \
        -d CONFIG_LTO_CLANG_THIN -d CONFIG_LTO_CLANG_FULL -e CONFIG_LTO_NONE
    
    # إضافات متقدمة لتعطيل الحماية بالكامل
    scripts/config --file ".config" -d CONFIG_RKP_CFP_JOPP -d CONFIG_UH_LKMAUTH -d CONFIG_UH_LKM_BLOCK
    scripts/config --file ".config" -d CONFIG_TIMA -d CONFIG_TIMA_LKMAUTH -d CONFIG_KNOX_KAP
    scripts/config --file ".config" -d CONFIG_SEC_RESTRICT_ROOTING -d CONFIG_SEC_RESTRICT_SETUID -d CONFIG_SEC_RESTRICT_FORK
    scripts/config --file ".config" -d CONFIG_INTEGRITY -d CONFIG_DM_VERITY
    scripts/config --file ".config" -d CONFIG_MODULE_SIG -d CONFIG_MODULE_SIG_FORCE -d CONFIG_MODULE_SIG_ALL
    
    scripts/config --file ".config" -e CONFIG_KPROBES -e CONFIG_HAVE_KPROBES -e CONFIG_KPROBE_EVENTS -e CONFIG_KSU
    scripts/config --file ".config" -e CONFIG_SECURITY_SELINUX_DEVELOP
    scripts/config --file ".config" -e CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE
    scripts/config --file ".config" -d CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE
    scripts/config --file ".config" --disable CONFIG_DEBUG_INFO_BTF --disable CONFIG_DEBUG_INFO
    scripts/config --file ".config" -e CONFIG_KERNEL_GZIP
else
    sed -i 's/CONFIG_SECURITY_DEFEX=y/# CONFIG_SECURITY_DEFEX is not set/g' .config
    echo -e "CONFIG_KPROBES=y\nCONFIG_HAVE_KPROBES=y\nCONFIG_KPROBE_EVENTS=y\nCONFIG_KSU=y\nCONFIG_KERNEL_GZIP=y\nCONFIG_DEBUG_INFO_BTF=n\nCONFIG_DEBUG_INFO=n" >> .config
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

# البحث عن Image أو Image.gz
if [ -f "arch/arm64/boot/Image.gz" ]; then
    mkdir -p "$BUILD_DIR"
    cp arch/arm64/boot/Image.gz "$BUILD_DIR/Image.gz"
    IMAGE_FILE="$BUILD_DIR/Image.gz"
elif [ -f "arch/arm64/boot/Image" ]; then
    mkdir -p "$BUILD_DIR"
    cp arch/arm64/boot/Image "$BUILD_DIR/Image"
    IMAGE_FILE="$BUILD_DIR/Image"
else
    error "فشل التجميع، لم يتم العثور على Image أو Image.gz."
fi

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

cp "$IMAGE_FILE" kernel
magiskboot repack boot.img
mv new-boot.img "$BUILD_DIR/boot.img"

echo -e "${GREEN}=== المرحلة 10: إنشاء AnyKernel3.zip ===${NC}"
if [[ "$AK3_CHOICE" == "y" || "$AK3_CHOICE" == "Y" ]]; then
    cd "$KERNEL_ROOT"
    if [ ! -d "AnyKernel3" ]; then
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    fi
    cp "$IMAGE_FILE" AnyKernel3/Image
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
    log "تم إنشاء AnyKernel3.zip في مجلد build/"
fi

echo -e "${GREEN}=== انتهى بنجاح! تم إنشاء boot.img المدمج بـ KernelSU ===${NC}"
ls -la "$BUILD_DIR"
