#!/usr/bin/env bash
set -euo pipefail

# v2rayNG 确定性 debug 构建 + secexp 签名脚本（移植自 xime/debug_build_secexp.sh）
# 所有依赖（Gradle 缓存、Android SDK、NDK、AAR、原生库、输出）都位于本仓库目录内部。

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
APP_DIR="$PROJECT_DIR/V2rayNG"

if (($#)); then
    echo "错误: 本脚本不使用命令行参数，请修改文件开头的“构建参数”配置区。" >&2
    exit 2
fi

# ============================================================
# apk_sign.py 以 xime 为权威源，构建前自动校齐；
# xime 不存在（如独立克隆环境）时跳过，使用本地现有副本。
# ============================================================
APK_SIGN_CANON="${APK_SIGN_CANON:-$PROJECT_DIR/../xime/apk_sign.py}"
if [[ -f "$APK_SIGN_CANON" ]] && ! cmp -s "$APK_SIGN_CANON" "$PROJECT_DIR/apk_sign.py"; then
    echo "同步 apk_sign.py: $APK_SIGN_CANON -> $PROJECT_DIR/apk_sign.py"
    cp -f "$APK_SIGN_CANON" "$PROJECT_DIR/apk_sign.py"
fi

# ============================================================
# 构建参数：需要调整时只修改本段。
# SECEXP 可用环境变量临时覆盖（支持 2**64+7 这类表达式）。
# ============================================================
unset BUILD_ABIS FLAVOR NDK_VERSION VERSION_CODE VERSION_NAME APPLICATION_ID

SECEXP="${SECEXP:-1}"                        # secexp 签名私钥指数
BUILD_ABIS="${BUILD_ABIS:-arm64-v8a}"        # 对应 -PABI_FILTERS，多个用分号分隔
FLAVOR="${FLAVOR:-playstore}"                # AGENTS.md 约定默认 Play Store 变体（可选 fdroid）
NDK_VERSION="${NDK_VERSION:-30.0.16248370}"  # 与 .github/workflows/build.yml 一致
APPLICATION_ID="${APPLICATION_ID:-qgb.n}"    # 包名（与 xime 版一致，环境变量可临时覆盖；fdroid 变体会追加 .fdroid 后缀）
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/out}"

# 与 xime 版不同：不再借用外层 ~/build_xime_home/.gradle 等共享目录，
# Gradle/Android 缓存与 SDK 全部放在 v2rayNG 目录内，与 xime 环境完全隔离。
GRADLE_USER_HOME="$PROJECT_DIR/.gradle"
ANDROID_USER_HOME="$PROJECT_DIR/.android"
SDK_DIR="$PROJECT_DIR/.android-sdk"
PLATFORM_JAR="$SDK_DIR/platforms/android-37/android.jar"
SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
LOG_FILE="$APP_DIR/gradle-secexp.log"
# ============================================================

case "$FLAVOR" in
    playstore|fdroid) ;;
    *)
        echo "错误: FLAVOR 只支持 playstore 或 fdroid：$FLAVOR" >&2
        exit 1
        ;;
esac

VERSION_NAME="${VERSION_NAME:-$(grep -oP '^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\K[^"]+' "$APP_DIR/app/build.gradle.kts" | head -n1)}"
VERSION_CODE="${VERSION_CODE:-$(grep -oP '^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*\K[0-9]+' "$APP_DIR/app/build.gradle.kts" | head -n1)}"
if [[ -z "$VERSION_NAME" || -z "$VERSION_CODE" ]]; then
    echo "错误: 无法从 V2rayNG/app/build.gradle.kts 解析 versionName/versionCode。" >&2
    exit 1
fi

export GRADLE_USER_HOME ANDROID_USER_HOME
export ANDROID_HOME="$SDK_DIR" ANDROID_SDK_ROOT="$SDK_DIR"
# 显式 mkdir -p 预先创建目录，防止 AGP 的 AndroidDirectoryCreator 崩溃。
mkdir -p "$GRADLE_USER_HOME" "$ANDROID_USER_HOME" "$SDK_DIR" "$OUT_DIR"

# ============================================================
# 1) 项目内 Android SDK 自举（平台 android-37、build-tools 37.0.0、NDK）
#    版本取自 .github/workflows/build.yml。
# ============================================================
ensure_sdk() {
    if [[ ! -d "$SDK_DIR/licenses" ]]; then
        local seed=/root/build_xime_home/.buildozer/android/platform/android-sdk/licenses
        if [[ -d "$seed" ]]; then
            cp -a "$seed" "$SDK_DIR/licenses"
        else
            mkdir -p "$SDK_DIR/licenses"
            printf '\n8933bad161af4178b1185d1a37fbf41ea5269c55\n24333f8a63b6825ea9c5514f83c2829b004d1fee\nd56f5187479451eabf01fb78af6dfcb131a6481e\n' \
                > "$SDK_DIR/licenses/android-sdk-license"
        fi
    fi

    if [[ ! -x "$SDKMANAGER" ]]; then
        local tmp zip_src=/root/build_xime_home/.buildozer/android/platform/android-sdk/commandlinetools-linux-6514223_latest.zip
        tmp="$(mktemp -d)"
        # 优先下载与 CI（android-actions/setup-android v4）一致的 cmdline-tools 14742923；
        # 本机 buildozer 的旧 zip（顶层 tools/，sdkmanager 过旧查不到 android-37）仅作离线兜底。
        if ! curl -fsSL --retry 3 -o "$tmp/cmdline-tools.zip" \
                "https://dl.google.com/android/repository/commandlinetools-linux-14742923_latest.zip"; then
            if [[ -f "$zip_src" ]]; then
                echo "警告: cmdline-tools 下载失败，回退使用本机旧 zip（可能查不到 android-37）。" >&2
                cp "$zip_src" "$tmp/cmdline-tools.zip"
            else
                echo "错误: 无法获取 cmdline-tools（下载失败且本地兜底 zip 不存在）。" >&2
                rm -rf "$tmp"
                exit 1
            fi
        fi
        unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"
        # 官方 zip 顶层是 cmdline-tools/；本机 buildozer 复用的 zip 顶层是 tools/
        local extracted=""
        if [[ -d "$tmp/cmdline-tools" ]]; then
            extracted="$tmp/cmdline-tools"
        elif [[ -d "$tmp/tools" ]]; then
            extracted="$tmp/tools"
        else
            echo "错误: cmdline-tools.zip 解压后未发现 cmdline-tools/ 或 tools/ 目录。" >&2
            rm -rf "$tmp"
            exit 1
        fi
        mkdir -p "$SDK_DIR/cmdline-tools"
        rm -rf "$SDK_DIR/cmdline-tools/latest"
        mv "$extracted" "$SDK_DIR/cmdline-tools/latest"
        rm -rf "$tmp"
    fi

    local -a pkgs=()
    [[ -x "$SDK_DIR/platform-tools/adb" ]] || pkgs+=("platform-tools")
    [[ -f "$PLATFORM_JAR" ]] || pkgs+=("platforms;android-37.0")
    [[ -x "$SDK_DIR/build-tools/37.0.0/aapt" ]] || pkgs+=("build-tools;37.0.0")
    [[ -d "$SDK_DIR/ndk/$NDK_VERSION" ]] || pkgs+=("ndk;$NDK_VERSION")
    if ((${#pkgs[@]})); then
        echo "安装 SDK 组件: ${pkgs[*]}"
        if ! "$SDKMANAGER" --sdk_root="$SDK_DIR" --install "${pkgs[@]}" \
                >"$SDK_DIR/sdkmanager.log" 2>&1 </dev/null; then
            tail -n 40 "$SDK_DIR/sdkmanager.log" >&2
            echo "错误: sdkmanager 安装失败，详见 $SDK_DIR/sdkmanager.log" >&2
            exit 1
        fi
    fi

    # platforms;android-37.0 可能装到 android-37.0 目录，AGP 需要的是 android-37
    if [[ ! -f "$PLATFORM_JAR" && -f "$SDK_DIR/platforms/android-37.0/android.jar" ]]; then
        ln -sfn android-37.0 "$SDK_DIR/platforms/android-37"
    fi
    if [[ ! -f "$PLATFORM_JAR" ]]; then
        echo "错误: SDK 组件安装后仍未找到 $PLATFORM_JAR" >&2
        exit 1
    fi
}
ensure_sdk

# ============================================================
# 2) 子模块 + 原生依赖：复现 build.yml 的 HEV / AAR 步骤，
#    产物全部放进 V2rayNG/app/libs（.gitignore 已忽略）。
# ============================================================
git submodule update --init --recursive

APP_LIBS="$APP_DIR/app/libs"
mkdir -p "$APP_LIBS"

AAR_TAG="$(git -C AndroidLibXrayLite describe --tags --abbrev=0)"
AAR_MARKER="$APP_LIBS/.libv2ray-aar-tag"
if [[ ! -f "$APP_LIBS/libv2ray.aar" ]] || [[ "$(cat "$AAR_MARKER" 2>/dev/null || true)" != "$AAR_TAG" ]]; then
    echo "下载 libv2ray.aar（tag=$AAR_TAG，与 AndroidLibXrayLite 子模块 gitlink 一致）"
    curl -fsSL --retry 3 -o "$APP_LIBS/libv2ray.aar" \
        "https://github.com/2dust/AndroidLibXrayLite/releases/download/$AAR_TAG/libv2ray.aar"
    printf '%s' "$AAR_TAG" > "$AAR_MARKER"
fi

HEV_HASH="$(git -C hev-socks5-tunnel rev-parse HEAD)|$(md5sum compile-hevtun.sh | cut -d' ' -f1)|$NDK_VERSION"
HEV_MARKER="$APP_LIBS/.hevtun-ok"
if [[ "$(cat "$HEV_MARKER" 2>/dev/null || true)" != "$HEV_HASH" ]]; then
    echo "编译 hev-socks5-tunnel（NDK $NDK_VERSION）"
    rm -rf "$PROJECT_DIR/libs"
    NDK_HOME="$SDK_DIR/ndk/$NDK_VERSION" bash "$PROJECT_DIR/compile-hevtun.sh"
    cp -r "$PROJECT_DIR/libs/." "$APP_LIBS/"
    printf '%s' "$HEV_HASH" > "$HEV_MARKER"
fi

# ============================================================
# 3) Gradle 构建（Play Store debug 变体，与 AGENTS.md 约定一致）
# ============================================================
FLAVOR_TASK="$(printf '%s' "$FLAVOR" | sed 's/^./\U&/')"
printf 'sdk.dir=%s\n' "$SDK_DIR" > "$APP_DIR/local.properties"

rm -rf "$APP_DIR/app/build/outputs/apk"
cd "$APP_DIR"
chmod 755 gradlew
echo "开始 Gradle 构建: assemble${FLAVOR_TASK}Debug（日志: $LOG_FILE）"
if ! ./gradlew --no-daemon "assemble${FLAVOR_TASK}Debug" \
        -PABI_FILTERS="$BUILD_ABIS" \
        -PapplicationId="$APPLICATION_ID" >"$LOG_FILE" 2>&1; then
    tail -n 100 "$LOG_FILE" >&2
    echo "错误: Gradle 构建失败，完整日志: $LOG_FILE" >&2
    exit 1
fi

# 4) 找到编译出的 APK
APK_OUT_DIR="$APP_DIR/app/build/outputs/apk/$FLAVOR/debug"
FIRST_ABI="${BUILD_ABIS%%;*}"
APK_PATH="$(find "$APK_OUT_DIR" -maxdepth 1 -type f -name "*${FIRST_ABI}*.apk" -print -quit)"
if [[ -z "$APK_PATH" ]]; then
    APK_PATH="$(find "$APK_OUT_DIR" -maxdepth 1 -type f -name '*.apk' -print -quit)"
fi
if [[ -z "$APK_PATH" ]]; then
    echo "错误: 未找到 debug APK，编译失败或输出命名和预期不一致。" >&2
    exit 1
fi

# 5) 先把 ZIP 元数据归一化，消除时间戳和文件顺序造成的差异，再签名
REPACKED_APK="$APK_OUT_DIR/repacked-${VERSION_CODE}-${FIRST_ABI}.apk"
python3 - "$APK_PATH" "$REPACKED_APK" <<'PY'
import sys
import zipfile
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

with zipfile.ZipFile(src, 'r') as zin:
    members = sorted(zin.infolist(), key=lambda i: i.filename)
    with zipfile.ZipFile(dst, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zout:
        for info in members:
            data = zin.read(info.filename)
            new_info = zipfile.ZipInfo(info.filename)
            new_info.compress_type = info.compress_type
            new_info.date_time = (1980, 1, 1, 0, 0, 0)
            new_info.extra = b''
            new_info.comment = b''
            new_info.create_system = 3
            new_info.external_attr = info.external_attr
            new_info.internal_attr = info.internal_attr
            zout.writestr(new_info, data)
PY
rm -f "$APK_PATH"
APK_PATH="$REPACKED_APK"

# 5b) Android 11+（R+，targetSdk>=30）强制要求 resources.arsc 等 STORED 条目
#     4 字节对齐，否则安装报 -124 "Failed parse during installPackageLI"。
#     上面的 Python 重打包只保留压缩方式、不保证对齐，必须在签名前补 zipalign
#     （对齐改字节，v2/v3 签名必须在其后）。zipalign 输入输出固定 → 仍然确定可复现。
ZIPALIGN_BIN="$(find "$SDK_DIR/build-tools" -maxdepth 2 -type f -name zipalign -print 2>/dev/null | sort -V | tail -n 1)"
if [[ -z "$ZIPALIGN_BIN" || ! -x "$ZIPALIGN_BIN" ]]; then
    echo "错误: 未找到可执行的 zipalign，SDK 路径: $SDK_DIR" >&2
    exit 1
fi
ALIGNED_APK="$APK_OUT_DIR/aligned-${VERSION_CODE}-${FIRST_ABI}.apk"
"$ZIPALIGN_BIN" -f -p 4 "$APK_PATH" "$ALIGNED_APK"
rm -f "$APK_PATH"
APK_PATH="$ALIGNED_APK"
"$ZIPALIGN_BIN" -c -p 4 "$APK_PATH"

# 6) 使用 apk_sign.py 通过 secexp 确定性生成签名密钥并签名
python3 "$PROJECT_DIR/apk_sign.py" "$APK_PATH" \
  --mode secexp \
  --secexp "$SECEXP" \
  --sdk "$SDK_DIR"

SIGNED_APK="${APK_PATH%.apk}-signed.apk"
if [[ ! -f "$SIGNED_APK" ]]; then
    echo "错误: 签名后 APK 未生成：$SIGNED_APK" >&2
    exit 1
fi

# 7) 复制一份到导出目录并校验
OUT_APK="$OUT_DIR/v2rayNG_${VERSION_NAME}_${FIRST_ABI}.apk"
cp -f "$SIGNED_APK" "$OUT_APK"
rm -f "$SIGNED_APK" "$APK_PATH"

APKSIGNER_BIN="$(find "$SDK_DIR/build-tools" -maxdepth 2 -type f -name apksigner -print 2>/dev/null | sort -V | tail -n 1)"
AAPT_BIN="$(find "$SDK_DIR/build-tools" -maxdepth 2 -type f -name aapt -print 2>/dev/null | sort -V | tail -n 1)"
if [[ -z "$APKSIGNER_BIN" || ! -x "$APKSIGNER_BIN" ]]; then
    echo "错误: 未找到可执行的 apksigner，SDK 路径: $SDK_DIR" >&2
    exit 1
fi
if [[ -z "$AAPT_BIN" || ! -x "$AAPT_BIN" ]]; then
    echo "错误: 未找到可执行的 aapt，SDK 路径: $SDK_DIR" >&2
    exit 1
fi

echo
echo "=== 已生成 APK ==="
ls -l "$OUT_APK"
sha256sum "$OUT_APK"

echo
echo "=== apksigner verify --print-certs ==="
"$APKSIGNER_BIN" verify --print-certs "$OUT_APK" 2>&1 | sed -n '1,40p'

echo
echo "=== aapt badging ==="
"$AAPT_BIN" dump badging "$OUT_APK" | grep -E 'package:|application-label:|native-code' || true

echo
echo "SECEXP=$SECEXP"
echo "APK=$OUT_APK"
