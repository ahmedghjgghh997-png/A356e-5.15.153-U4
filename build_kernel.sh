#!/bin/bash
# ============================================================
# سكريبت بناء نواة Samsung Galaxy A35 (Exynos 1380) مع KernelSU
# ============================================================

set -e

# الألوان
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

# ========== 1. إدخال الروابط ==========
if [ -n "$GITHUB_ACTIONS" ]; then
    KERNEL_URL="$INPUT_KERNEL_URL"
    BOOT_URL="$INPUT_BOOT_URL"
else
    echo -e "${GREEN}=== الخطوة 1: إدخال الروابط ===${NC}"
    read -p "رابط سورس النواة: " KERNEL_URL
    read -p "رابط boot.img الأصلي (مهم جداً للروت): " BOOT_URL
fi

[ -z "$KERNEL_URL" ] && error "رابط السورس مطلوب."
[ -z "$BOOT_URL" ] && warn "بدون boot.img أصلي، لن تحصل على ملف جاهز للتفليش!"

# ========== 2. تثبيت التبعيات ==========
log "تثبيت التبعيات..."
sudo apt update && sudo apt install -y bc bison build-essential curl git git-lfs \
    libelf-dev libssl-dev lz4 python3 python3-pip zip zstd clang lld

# ========== 3. تحضير سلاسل الأدوات (Clang 17) ==========
mkdir -p "$TOOLCHAINS_DIR"
if [ ! -d "$TOOLCHAINS_DIR/clang" ]; then
    log "تحميل Clang المخصص للأندرويد..."
    cd "$TOOLCHAINS_DIR"
    curl -LSs "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r522817.tar.gz" -o clang.tar.gz
    mkdir clang && tar -xzf clang.tar.gz -C clang && rm clang.tar.gz
    cd - >/dev/null
fi

export PATH="$TOOLCHAINS_DIR/clang/bin:$PATH"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-

# ========== 4. تحميل سورس النواة ==========
rm -rf "$KERNEL_ROOT" && mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"
log "جاري تحميل سورس النواة..."
git clone --depth=1 "$KERNEL_URL" . || (curl -L "$KERNEL_URL" -o src.tar.gz && tar -xf src.tar.gz --strip-components=1)

# ========== 5. دمج KernelSU (الروت) ==========
log "جاري دمج كود KernelSU في السورس..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# ========== 6. تحضير الـ Defconfig ==========
DEFCONFIG="s5e8835-a35xjvxx_defconfig"
log "تجهيز الإعدادات ($DEFCONFIG)..."
make ARCH=arm64 CC=clang $DEFCONFIG

# تفعيل إعدادات الروت والحماية
scripts/config --file ".config" \
    -e CONFIG_KSU \
    -e CONFIG_OVERLAY_FS \
    -e CONFIG_KPROBES \
    -e CONFIG_KPROBE_EVENTS \
    -d CONFIG_UH -d CONFIG_UH_RKP -d CONFIG_RKP_CFP \
    -d CONFIG_SECURITY_DEFEX -d CONFIG_PROCA -d CONFIG_FIVE \
    -d CONFIG_MODULE_SIG_FORCE

# ========== 7. التجميع (Building) ==========
log "بدء التجميع (هذه الخطوة تستغرق وقتاً)..."
make -j$(nproc) ARCH=arm64 CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    Image 2>&1 | tee -a "$LOG_FILE"

if [ ! -f "arch/arm64/boot/Image" ]; then
    error "فشل التجميع! راجع build.log"
fi

# ========== 8. صناعة boot.img الـ Rooted ==========
if [ -n "$BOOT_URL" ]; then
    log "بدء عملية حقن النواة في boot.img الأصلي لعمل الروت..."
    mkdir -p "$BUILD_DIR"
    curl -L -o "$BUILD_DIR/stock_boot.img" "$BOOT_URL"
    
    # تحميل magiskboot (الأداة السحرية للتعامل مع البوت)
    curl -L "https://github.com/magisk-modules-alt-repo/magiskboot_x86_64/raw/main/magiskboot" -o magiskboot
    chmod +x magiskboot
    
    cp arch/arm64/boot/Image .
    ./magiskboot unpack "$BUILD_DIR/stock_boot.img"
    
    # استبدال النواة القديمة بالجديدة (المحتوية على KernelSU)
    mv Image kernel
    ./magiskboot repack "$BUILD_DIR/stock_boot.img" "$BUILD_DIR/rooted_boot.img"
    
    log "مبروك! تم إنشاء ملف البوت المروت في: $BUILD_DIR/rooted_boot.img"
else
    mkdir -p "$BUILD_DIR"
    cp arch/arm64/boot/Image "$BUILD_DIR/"
    warn "تم بناء النواة فقط (Image). لم يتم إنشاء boot.img لعدم توفر الرابط."
fi

log "انتهت العملية بنجاح."
