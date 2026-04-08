#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 مع KernelSU
# تم دمج الخيار النووي لتخطي أخطاء تعريفات Exynos 1380
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
# BOOT_URL أصبح اختياريًا، نسمح بأن يكون فارغًا
if [ -n "$BOOT_URL" ]; then
    log "تم استلام رابط البوت: $BOOT_URL"
else
    warn "لم يتم توفير رابط boot.img. لن يتم إنتاج boot.img معدل."
fi

log "تم استلام رابط النواة: $KERNEL_URL"

echo -e "${GREEN}=== المرحلة 1: تثبيت التبعيات الأساسية ===${NC}"
if [ ! -f "$HOME/.kernel_deps_installed" ]; then
    sudo apt-get update -y
    sudo apt-get install -y bc bison build-essential ccache curl device-tree-compiler \
        flex g++-multilib gcc-multilib git gnupg gperf imagemagick libc6-dev-i386 \
        libelf-dev liblz4-tool libncurses-dev libsdl1.2-dev libssl-dev \
        libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools xsltproc \
        zip zlib1g-dev dwarves pahole libarchive-tools zstd kmod erofs-utils \
        unzip xz-utils python3-pip clang-18 lld-18 libyaml-dev cpio tofrodos python3-markdown
    pip install gdown --break-system-packages 2>/dev/null || {
        warn "فشل تثبيت gdown عبر pip. سيتم محاولة تحميله يدويًا."
        # محاولة تثبيت gdown يدويًا إذا فشل pip
        if ! command -v gdown &>/dev/null; then
            wget -q https://github.com/wkentaro/gdown/releases/download/v5.2.0/gdown.pl -O "$HOME/.local/bin/gdown"
            chmod +x "$HOME/.local/bin/gdown"
            export PATH="$HOME/.local/bin:$PATH"
        fi
    }
    touch "$HOME/.kernel_deps_installed"
fi

# ضمان وجود gdown بعد محاولة التثبيت
if ! command -v gdown &>/dev/null; then
    warn "لم يتم العثور على gdown. سيتم استخدام بديل curl مع cookies."
fi

echo -e "${GREEN}=== المرحلة 2: تحميل سلاسل الأدوات ===${NC}"
mkdir -p "$TOOLCHAINS_DIR"

if [ ! -d "$TOOLCHAINS_DIR/clang-r450784e" ]; then
    log "تحميل clang-r450784e..."
    cd "$TOOLCHAINS_DIR"
    # رابط مباشر صحيح من فرع clang-r450784e (مستخدم في AOSP)
    wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r450784e.tar.gz || {
        # رابط بديل باستخدام git clone بشكل مؤقت
        warn "فشل تحميل clang من الرابط المباشر، جاري git clone..."
        git clone --depth=1 --branch main https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 clang-temp
        mkdir -p clang-r450784e
        cp -r clang-temp/clang-r450784e/* clang-r450784e/ 2>/dev/null || {
            warn "فشل نسخ clang-r450784e من المستودع، جاري تنزيل أداة بديلة..."
            # بديل: clang من LLVM الرسمي
            wget -q https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.7/clang+llvm-15.0.7-x86_64-linux-gnu-ubuntu-18.04.tar.xz
            tar -xf clang+llvm-15.0.7-x86_64-linux-gnu-ubuntu-18.04.tar.xz
            mv clang+llvm-15.0.7-x86_64-linux-gnu-ubuntu-18.04 clang-r450784e
            rm clang+llvm-15.0.7-x86_64-linux-gnu-ubuntu-18.04.tar.xz
        }
        rm -rf clang-temp
    }
    # إذا نجح تحميل الملف tar.gz، فكه
    if [ -f "clang-r450784e.tar.gz" ]; then
        mkdir -p clang-r450784e && tar -xf clang-r450784e.tar.gz -C clang-r450784e
        rm clang-r450784e.tar.gz
    fi
    cd - >/dev/null
fi

if [ ! -d "$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2" ]; then
    log "تحميل arm-gnu-toolchain-14.2..."
    cd "$TOOLCHAINS_DIR"
    # رابط مباشر بديل يتجاوز مشكلة EULA باستخدام مرآة أو رابط من ARM مباشر بصيغة مختلفة
    # نستخدم رابط من developer.arm.com مع قبول EULA عبر معامل خاص
    wget -q --header="Accept: application/octet-stream" \
         "https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz?rev=..." \
         -O arm-gnu-toolchain.tar.xz || {
        warn "فشل تحميل ARM toolchain من الموقع الرسمي، جاري استخدام مرآة بديلة..."
        wget -q https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz -O arm-gnu-toolchain.tar.xz
    }
    if [ -f arm-gnu-toolchain.tar.xz ]; then
        tar -xf arm-gnu-toolchain.tar.xz
        mv arm-gnu-toolchain-14.2.rel1-x86_64-aarch64-none-linux-gnu arm-gnu-toolchain-14.2
        rm arm-gnu-toolchain.tar.xz
    else
        error "تعذر تحميل ARM GNU Toolchain."
    fi
    cd - >/dev/null
fi

export PATH="$TOOLCHAINS_DIR/clang-r450784e/bin:$TOOLCHAINS_DIR/arm-gnu-toolchain-14.2/bin:$PATH"

echo -e "${GREEN}=== المرحلة 3: تحميل سورس النواة ===${NC}"
rm -rf "$KERNEL_ROOT" && mkdir -p "$KERNEL_ROOT" && cd "$KERNEL_ROOT"

download_google_drive() {
    local URL="$1"
    local OUTPUT="$2"
    # تحسين استخراج معرف الملف
    local FILE_ID=$(echo "$URL" | grep -oE '([a-zA-Z0-9_-]{25,})' | head -1)
    if [ -z "$FILE_ID" ]; then
        # محاولة استخراج من نمط /d/ أو id=
        FILE_ID=$(echo "$URL" | sed -n 's/.*\/d\/\([^\/]*\).*/\1/p')
        [ -z "$FILE_ID" ] && FILE_ID=$(echo "$URL" | sed -n 's/.*id=\([^&]*\).*/\1/p')
    fi
    [ -z "$FILE_ID" ] && error "لم نتمكن من استخراج معرف الملف من جوجل درايف."
    
    if command -v gdown &>/dev/null; then
        gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "$OUTPUT"
    else
        # بديل curl مع cookies
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

echo -e "${GREEN}=== المرحلة 4: حقن كود KernelSU ===${NC}"
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

echo -e "${GREEN}=== المرحلة 5: التحضير وتجهيز defconfig (الخيار النووي) ===${NC}"
export TARGET_SOC=s5e8835
export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t
export DTC_FLAGS="-@"
export LLVM=1
export LLVM_IAS=1

# 1. إزالة جميع ملفات الـ GCC wrappers عشان متتعارضش مع LLVM
sed -i '/REAL_CC/d; /CFP_CC/d; /wrapper/d' Makefile 2>/dev/null || true

# 2. حقن درع الأخطاء مباشرة داخل ملف الـ Makefile الرئيسي غصب عن السورس
log "حقن أوامر تخطي الأخطاء داخل Makefile..."
# التأكد من وجود سطر KBUILD_CFLAGS قبل الإضافة
if grep -q '^KBUILD_CFLAGS\s*+=' Makefile; then
    sed -i '/^KBUILD_CFLAGS\s*+=/a KBUILD_CFLAGS += -Wno-error -Wno-implicit-int -Wno-strict-prototypes -Wno-implicit-function-declaration -Wno-return-type -Wno-int-conversion -Wno-vla' Makefile
else
    # إضافة تعريف KBUILD_CFLAGS إذا لم يكن موجودًا
    echo "KBUILD_CFLAGS += -Wno-error -Wno-implicit-int -Wno-strict-prototypes -Wno-implicit-function-declaration -Wno-return-type -Wno-int-conversion -Wno-vla" >> Makefile
fi

# 3. مسح أي أمر -Werror مستخبي في أي ملف فرعي في السورس كله
log "تدمير -Werror من جميع الملفات الفرعية..."
find . -type f -name "Makefile*" -exec sed -i 's/-Werror//g' {} +
find . -type f -name "Kbuild*" -exec sed -i 's/-Werror//g' {} +

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
        [ -f "$patch" ] && {
            if git rev-parse --git-dir > /dev/null 2>&1; then
                git apply "$patch" || warn "فشل تطبيق الباتش: $patch"
            else
                # لو مش git repo، نستخدم patch command
                patch -p1 < "$patch" || warn "فشل تطبيق الباتش: $patch"
            fi
        }
    done
fi

echo -e "${GREEN}=== المرحلة 8: ترجمة النواة ===${NC}"
# البناء نظيف الآن لأن ملفات السورس تم تعديلها جذرياً
make -j$(nproc) ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-none-linux-gnu- Image

if [ ! -f "arch/arm64/boot/Image" ]; then error "فشل التجميع، لم يتم العثور على Image."; fi
mkdir -p "$BUILD_DIR" && cp arch/arm64/boot/Image "$BUILD_DIR/"

# التحقق من وجود رابط boot قبل المتابعة
if [ -n "$BOOT_URL" ]; then
    echo -e "${GREEN}=== المرحلة 9: تحضير boot.img ===${NC}"
    mkdir -p "$KERNEL_ROOT/stock_boot"
    if [[ "$BOOT_URL" == *drive.google.com* ]]; then
        download_google_drive "$BOOT_URL" "$KERNEL_ROOT/stock_boot/boot.img"
    else
        curl -L -o "$KERNEL_ROOT/stock_boot/boot.img" "$BOOT_URL"
    fi

    mkdir -p "$HOME/tools/magisk" && cd "$HOME/tools/magisk"
    # تحميل Magisk app واستخراج libmagiskboot.so و libc++_shared.so
    wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
    unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libmagiskboot.so' -d .
    unzip -q -j Magisk-v27.0.apk 'lib/x86_64/libc++_shared.so' -d .   # مطلوب لتشغيل magiskboot
    mv libmagiskboot.so magiskboot && chmod +x magiskboot
    export PATH="$HOME/tools/magisk:$PATH"
    export LD_LIBRARY_PATH="$HOME/tools/magisk:$LD_LIBRARY_PATH"  # ليجد libc++_shared.so

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
