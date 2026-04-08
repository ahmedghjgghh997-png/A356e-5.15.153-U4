#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 مع KernelSU (الإصدار النهائي - ثابت)
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
if [ -n "$BOOT_URL" ]; then
    log "تم استلام رابط البوت: $BOOT_URL"
else
    warn "لم يتم توفير رابط boot.img. لن يتم إنتاج boot.img معدل."
fi

log "تم استلام رابط النواة: $KERNEL_URL"

echo -e "${GREEN}=== المرحلة 1: تثبيت التبعيات الأساسية ===${NC}"
if [ ! -f "$HOME/.kernel_deps_installed" ]; then
    sudo apt-get update -y
    sudo apt-get install -y git device-tree-compiler lz4 xz-utils zlib1g-dev openjdk-17-jdk \
        gcc g++ python3 python-is-python3 p7zip-full android-sdk-libsparse-utils erofs-utils \
        default-jdk gnupg flex bison gperf build-essential zip curl libc6-dev libncurses-dev \
        libx11-dev libreadline-dev libgl1 libgl1-mesa-dev make bc grep tofrodos \
        python3-markdown libxml2-utils xsltproc cpio kmod openssl libelf-dev pahole \
        libssl-dev libarchive-tools zstd rsync --fix-missing
    
    wget -q http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb -O /tmp/libtinfo5.deb && \
        sudo dpkg -i /tmp/libtinfo5.deb 2>/dev/null || warn "libtinfo5 غير متوفر (قد لا يكون ضرورياً)."
    
    pip install gdown --break-system-packages 2>/dev/null || {
        warn "فشل تثبيت gdown عبر pip. سيتم محاولة تحميله يدويًا."
        if ! command -v gdown &>/dev/null; then
            wget -q https://github.com/wkentaro/gdown/releases/download/v5.2.0/gdown.pl -O "$HOME/.local/bin/gdown"
            chmod +x "$HOME/.local/bin/gdown"
            export PATH="$HOME/.local/bin:$PATH"
        fi
    }
    touch "$HOME/.kernel_deps_installed"
fi

if ! command -v gdown &>/dev/null; then
    warn "لم يتم العثور على gdown. سيتم استخدام بديل curl مع cookies."
fi

echo -e "${GREEN}=== المرحلة 2: تحميل سلاسل الأدوات ===${NC}"
mkdir -p "$TOOLCHAINS_DIR"

# ------------------------------
# تحميل Clang من رابط مباشر موثوق (مع احتياط)
# ------------------------------
if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    log "تحميل clang-r450784e..."
    cd "$TOOLCHAINS_DIR"
    
    CLANG_URL="https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/clang-r450784e.tar.gz"
    CLANG_URL_BACKUP="https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r450784e/archive/refs/heads/lineage-20.0.tar.gz"
    
    wget --tries=5 --timeout=30 "$CLANG_URL" -O clang.tar.gz || {
        warn "فشل التحميل من الرابط الأساسي، جاري المحاولة من الرابط الاحتياطي..."
        wget --tries=5 --timeout=30 "$CLANG_URL_BACKUP" -O clang.tar.gz || error "تعذر تحميل Clang من أي مصدر."
    }
    
    log "فك ضغط Clang..."
    mkdir -p clang-temp
    tar -xf clang.tar.gz -C clang-temp
    
    if [ -d "clang-temp/clang-r450784e" ]; then
        mv clang-temp/clang-r450784e ./
    elif [ -d "clang-temp"/*/clang-r450784e ]; then
        mv clang-temp/*/clang-r450784e ./
    else
        mkdir -p clang-r450784e
        mv clang-temp/* clang-r450784e/
    fi
    
    rm -rf clang-temp clang.tar.gz
    log "تم تحميل clang-r450784e بنجاح."
    cd - >/dev/null
fi

# ------------------------------
# تحميل ARM GNU Toolchain (من Linaro حصراً)
# ------------------------------
if [ ! -d "$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2" ]; then
    log "تحميل arm-gnu-toolchain-14.2 من Linaro..."
    cd "$TOOLCHAINS_DIR"
    
    GCC_URL="https://releases.linaro.org/components/toolchain/binaries/latest/armv8l-linux-gnueabihf/gcc-linaro-14.2.1-2025.01-x86_64_aarch64-linux-gnu.tar.xz"
    
    wget --tries=5 --timeout=30 "$GCC_URL" -O gcc.tar.xz || {
        error "فشل تحميل ARM Toolchain من Linaro بعد عدة محاولات."
    }
    
    if ! tar -tf gcc.tar.xz &>/dev/null; then
        error "الملف المحمل غير صالح (ليس أرشيف tar.xz)."
    fi
    
    log "فك ضغط ARM Toolchain..."
    tar -xf gcc.tar.xz
    mv gcc-linaro-* arm-gnu-toolchain-14.2
    rm gcc.tar.xz
    
    log "تم تحميل arm-gnu-toolchain-14.2 بنجاح."
    cd - >/dev/null
fi

export PATH="$TOOLCHAINS_DIR/clang-r450784e/bin:$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2/bin:$PATH"

echo -e "${GREEN}=== المرحلة 3: تحميل سورس النواة ===${NC}"
rm -rf "$KERNEL_ROOT" && mkdir -p "$KERNEL_ROOT" && cd "$KERNEL_ROOT"

download_google_drive() {
    local URL="$1"
    local OUTPUT="$2"
    local FILE_ID=$(echo "$URL" | grep -oE '([a-zA-Z0-9_-]{25,})' | head -1)
    if [ -z "$FILE_ID" ]; then
        FILE_ID=$(echo "$URL" | sed -n 's/.*\/d\/\([^\/]*\).*/\1/p')
        [ -z "$FILE_ID" ] && FILE_ID=$(echo "$URL" | sed -n 's/.*id=\([^&]*\).*/\1/p')
    fi
    [ -z "$FILE_ID" ] && error "لم نتمكن من استخراج معرف الملف من جوجل درايف."
    
    if command -v gdown &>/dev/null; then
        gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$OUTPUT"
    else
        log "استخدام curl لتحميل من Google Drive..."
        curl -L -b /tmp/cookies -c /tmp/cookies "https://drive.google.com/uc?export=download&id=${FILE_ID}" -o "$OUTPUT"
    fi
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

log "إصلاح أذونات مجلد النواة..."
chmod -R 755 "$KERNEL_ROOT"

echo -e "${GREEN}=== المرحلة 4: حقن كود KernelSU ===${NC}"
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

echo -e "${GREEN}=== المرحلة 5: التحضير وتجهيز defconfig (الخيار النووي) ===${NC}"
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t
export DTC_FLAGS="-@"
export LLVM=1
export LLVM_IAS=1

DEFCONFIG="s5e8835-a35xjvxx_defconfig"

if [ -f "arch/arm64/configs/$DEFCONFIG" ] && [ ! -f "arch/arm64/configs/stock_defconfig" ]; then
    cp "arch/arm64/configs/$DEFCONFIG" "arch/arm64/configs/stock_defconfig"
    log "تم نسخ defconfig إلى stock_defconfig لمنع رسالة الخطأ."
fi

sed -i '/REAL_CC/d; /CFP_CC/d; /wrapper/d' Makefile 2>/dev/null || true

log "حقن أوامر تخطي الأخطاء داخل Makefile..."
if grep -q '^KBUILD_CFLAGS\s*+=' Makefile; then
    sed -i '/^KBUILD_CFLAGS\s*+=/a KBUILD_CFLAGS += -Wno-error -Wno-implicit-int -Wno-strict-prototypes -Wno-implicit-function-declaration -Wno-return-type -Wno-int-conversion -Wno-vla' Makefile
else
    echo "KBUILD_CFLAGS += -Wno-error -Wno-implicit-int -Wno-strict-prototypes -Wno-implicit-function-declaration -Wno-return-type -Wno-int-conversion -Wno-vla" >> Makefile
fi

log "تدمير -Werror من جميع الملفات الفرعية..."
find . -type f -name "Makefile*" -exec sed -i 's/-Werror//g' {} +
find . -type f -name "Kbuild*" -exec sed -i 's/-Werror//g' {} +

sed -i 's|scripts/kconfig/conf --olddefconfig Kconfig|scripts/kconfig/conf --olddefconfig --defconfig=arch/arm64/configs/stock_defconfig Kconfig|g' scripts/kconfig/Makefile 2>/dev/null || true

make ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-none-linux-gnu- $DEFCONFIG

echo -e "${GREEN}=== المرحلة 6: تعطيل حماية سامسونج وتفعيل KSU ===${NC}"
if [ -f "scripts/config" ]; then
    scripts/config --file ".config" -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_UH_LKMAUTH -d CONFIG_UH_LKM_BLOCK \
        -d CONFIG_RKP_CFP -d CONFIG_RKP_CFP_JOPP \
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
        [ -f "$patch" ] && {
            if git rev-parse --git-dir > /dev/null 2>&1; then
                git apply "$patch" || warn "فشل تطبيق الباتش: $patch"
            else
                patch -p1 < "$patch" || warn "فشل تطبيق الباتش: $patch"
            fi
        }
    done
fi

if [[ "$APPLY_LEGACY_FIXES" == "1" ]]; then
    echo -e "${GREEN}=== المرحلة 7.5: تطبيق باتشات إصلاح النواة القديمة ===${NC}"
    log "تحميل مستودع الباتشات..."
    git clone --depth=1 https://github.com/ravindu644/Android-Kernel-Tutorials.git patches_repo
    
    for patch in \
        "patches/018.yylloc.patch" \
        "patches/020.sec_debug_test.patch" \
        "patches/015.fix_gen_kheaders.sh_cpio_not_found.patch"
    do
        if [ -f "patches_repo/$patch" ]; then
            log "تطبيق $patch ..."
            patch -p1 < "patches_repo/$patch" || warn "فشل تطبيق $patch"
        fi
    done
    rm -rf patches_repo
fi

echo -e "${GREEN}=== المرحلة 8: ترجمة النواة ===${NC}"
make -j$(nproc) ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-none-linux-gnu- Image

if [ ! -f "arch/arm64/boot/Image" ]; then error "فشل التجميع، لم يتم العثور على Image."; fi
mkdir -p "$BUILD_DIR" && cp arch/arm64/boot/Image "$BUILD_DIR/"

if [ -n "$BOOT_URL" ]; then
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
    unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libc++_shared.so' -d .
    mv libmagiskboot.so magiskboot && chmod +x magiskboot
    export PATH="$HOME/tools/magisk:$PATH"
    export LD_LIBRARY_PATH="$HOME/tools/magisk:$LD_LIBRARY_PATH"

    cd "$KERNEL_ROOT"
    mkdir -p boot_work && cp "$KERNEL_ROOT/stock_boot/boot.img" boot_work/
    cd boot_work
    magiskboot unpack boot.img

    rm -f kernel kernel.lz4 kernel.gz kernel.bz2

    cp "$BUILD_DIR/Image" kernel
    magiskboot repack boot.img
    mv new-boot.img "$BUILD_DIR/boot.img"
else
    warn "تخطي مرحلة boot.img لعدم وجود رابط boot_url."
fi

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

echo -e "${GREEN}=== انتهى بنجاح! تم إنشاء Image$( [ -n "$BOOT_URL" ] && echo " و boot.img المدمج بـ KernelSU") ===${NC}"
ls -la "$BUILD_DIR"
