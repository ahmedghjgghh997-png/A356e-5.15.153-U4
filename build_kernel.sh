#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 مع KernelSU
# (متوافق مع GitHub Actions - Ubuntu 24.04)
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

# ========== 0. الروابط (من متغيرات البيئة) ==========
KERNEL_URL="${INPUT_KERNEL_URL}"
BOOT_URL="${INPUT_BOOT_URL}"
AK3_CHOICE="${AK3_CHOICE_ENV:-n}"

[ -z "$KERNEL_URL" ] && error "رابط سورس النواة فارغ!"
if [ -z "$BOOT_URL" ]; then
    warn "رابط boot.img غير متوفر. لن يتم إنشاء boot.img."
fi

log "رابط النواة: $KERNEL_URL"
[ -n "$BOOT_URL" ] && log "رابط boot.img: $BOOT_URL"

# ========== 1. تثبيت التبعيات الأساسية ==========
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

# ========== 2. إنشاء رابط رمزي لـ ld.lld (لتجنب خطأ not found) ==========
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

# ========== 4. KernelSU ==========
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# ========== 5. متغيرات سامسونج وإعدادات الترجمة ==========
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t
export DTC_FLAGS="-@"
export LLVM=1
export LLVM_IAS=1

# استخدام clang-18 من النظام (بدلاً من تحميل toolchains يدويًا)
export CC=clang-18
export LD=ld.lld-18
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_TRIPLE=aarch64-linux-gnu-

# ========== 6. defconfig ==========
DEFCONFIG="s5e8835-a35xjvxx_defconfig"
make ARCH=arm64 CC=$CC LD=$LD CROSS_COMPILE=$CROSS_COMPILE CLANG_TRIPLE=$CLANG_TRIPLE LLVM=1 LLVM_IAS=1 $DEFCONFIG

if [ ! -f "arch/arm64/configs/stock_defconfig" ]; then
    cp "arch/arm64/configs/$DEFCONFIG" "arch/arm64/configs/stock_defconfig"
fi

# ========== 7. دمج custom.config (إذا كان موجودًا) ==========
if [ -f "../custom.config" ]; then
    log "دمج custom.config"
    cp ../custom.config .
    scripts/kconfig/merge_config.sh -m -O . .config custom.config
    make ARCH=arm64 CC=$CC LD=$LD CROSS_COMPILE=$CROSS_COMPILE CLANG_TRIPLE=$CLANG_TRIPLE LLVM=1 LLVM_IAS=1 olddefconfig
fi

# ========== 8. تعطيل حماية سامسونج وتفعيل KSU ==========
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

make ARCH=arm64 CC=$CC LD=$LD CROSS_COMPILE=$CROSS_COMPILE CLANG_TRIPLE=$CLANG_TRIPLE LLVM=1 LLVM_IAS=1 olddefconfig

# ========== 9. تطبيق الباتشات (إذا وجدت) ==========
if [ -d "$PWD/patches" ]; then
    log "تطبيق الباتشات من مجلد patches/"
    for patch in patches/*.patch; do
        [ -f "$patch" ] && git apply "$patch" 2>/dev/null || true
    done
fi

# ========== 10. ترجمة النواة ==========
export SHIELD_FLAGS="-w -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-incompatible-pointer-types -Wno-pointer-sign -Wno-vla -Wno-int-conversion -Wno-return-type -Wno-implicit-fallthrough -fgnu89-inline"
export KCPPFLAGS="-Wno-error"

make -j$(nproc) ARCH=arm64 CC=$CC LD=$LD CROSS_COMPILE=$CROSS_COMPILE CLANG_TRIPLE=$CLANG_TRIPLE LLVM=1 LLVM_IAS=1 KCFLAGS="$SHIELD_FLAGS" KCPPFLAGS="$KCPPFLAGS" Image

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

# ========== 11. تحضير boot.img (إذا تم توفير رابط) ==========
if [ -n "$BOOT_URL" ]; then
    log "تحضير boot.img..."
    mkdir -p stock_boot
    if [[ "$BOOT_URL" == *drive.google.com* ]]; then
        download_google_drive "$BOOT_URL" stock_boot/boot.img
    else
        curl -L -o stock_boot/boot.img "$BOOT_URL"
    fi
    [ -f "stock_boot/boot.img" ] || error "فشل تحميل boot.img"

    # تثبيت magiskboot
    if ! command -v magiskboot &> /dev/null; then
        mkdir -p "$HOME/tools/magisk" && cd "$HOME/tools/magisk"
        wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
        unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libmagiskboot.so' -d .
        mv libmagiskboot.so magiskboot && chmod +x magiskboot
        export PATH="$HOME/tools/magisk:$PATH"
        cd "$KERNEL_ROOT"
    fi

    mkdir -p boot_work && cp stock_boot/boot.img boot_work/
    cd boot_work
    magiskboot unpack boot.img
    cp "$IMAGE_FILE" kernel
    magiskboot repack boot.img
    mv new-boot.img "$BUILD_DIR/boot.img"
    cd ..
    log "تم إنشاء boot.img"
fi

# ========== 12. AnyKernel3.zip (اختياري) ==========
if [[ "$AK3_CHOICE" == "y" || "$AK3_CHOICE" == "Y" ]]; then
    log "إنشاء AnyKernel3.zip..."
    cd "$KERNEL_ROOT"
    [ ! -d "AnyKernel3" ] && git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git
    cp "$IMAGE_FILE" AnyKernel3/Image
    cd AnyKernel3
    zip -r9 "../build/AnyKernel3-$(date +%Y%m%d-%H%M%S).zip" . -x ".git*" "README.md" "*.zip"
    cd ..
    log "تم إنشاء AnyKernel3.zip"
fi

echo -e "${GREEN}=== نجح البناء! المخرجات في: $BUILD_DIR ===${NC}"
ls -la "$BUILD_DIR"
