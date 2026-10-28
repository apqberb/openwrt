#!/bin/bash
# =============================================================================
# OpenWrt 智能编译工具 - 云端构建脚本（在 GitHub Actions Runner 中执行）
#
# 输入（全部通过环境变量传入，由 workflow_dispatch inputs 映射）：
#   SOURCE_REPO     上游源码仓库地址（openwrt / lede / immortalwrt / lienol）
#   SOURCE_BRANCH   上游分支
#   TARGET          架构，例如 x86、bcm27xx、ramips、rockchip
#   SUBTARGET       子目标，例如 64、bcm2711、mt7621、armv8
#   PROFILE         设备 PROFILE，例如 generic、rpi-4（仅记录，设备由 .config 决定）
#   PLUGINS         逗号分隔的插件 id（仅用于记录）
#   FEEDS_B64       base64 编码的 feeds.conf.default（空则用源码自带）
#   CONFIG_B64      base64 编码的 .config 种子文件
#   BUILD_ID        工具侧任务 id（同时作为 Artifact 名称与 Release tag）
#   BUILD_NAME      任务名称
#
# 产物：$WORKDIR/firmware/（固件镜像、manifest、sha256sums、build-info.json）
# =============================================================================
set -euo pipefail

WORKDIR="$PWD"
BUILD_DIR="$WORKDIR/openwrt"
OUT_DIR="$WORKDIR/firmware"
LOG_FILE="$WORKDIR/build.log"

require() {
  if [ -z "${!1:-}" ]; then
    echo "::error::缺少必需环境变量 $1"
    exit 1
  fi
}
require SOURCE_REPO
require SOURCE_BRANCH
require TARGET
require SUBTARGET
require CONFIG_B64
BUILD_ID="${BUILD_ID:-manual-$(date +%Y%m%d%H%M%S)}"
BUILD_NAME="${BUILD_NAME:-手动构建}"
PROFILE="${PROFILE:-}"
PLUGINS="${PLUGINS:-}"

echo "::group::1/7 克隆上游源码"
echo "  仓库: $SOURCE_REPO"
echo "  分支: $SOURCE_BRANCH"
rm -rf "$BUILD_DIR"
git clone --depth 1 --single-branch --branch "$SOURCE_BRANCH" "$SOURCE_REPO" "$BUILD_DIR"
cd "$BUILD_DIR"
echo "源码版本: $(git rev-parse --short HEAD)"
echo "::endgroup::"

echo "::group::2/7 配置 feeds.conf.default"
if [ -n "${FEEDS_B64:-}" ]; then
  echo "$FEEDS_B64" | base64 -d > feeds.conf.default
  echo "写入自定义 feeds.conf.default："
  cat feeds.conf.default
else
  echo "未提供自定义 feeds，使用源码自带配置："
  cat feeds.conf.default 2>/dev/null || echo "(源码未自带 feeds.conf.default)"
fi
echo "::endgroup::"

echo "::group::3/7 更新并安装 feeds"
./scripts/feeds update -a
./scripts/feeds install -a
echo "::endgroup::"

echo "::group::4/7 写入 .config 并执行 defconfig"
echo "$CONFIG_B64" | base64 -d > .config
# 备份种子配置，便于失败诊断
cp .config "$WORKDIR/seed.config"
echo "--- 种子 .config（节选） ---"
grep -E '^CONFIG_TARGET|^CONFIG_PACKAGE_(luci|kmod)' .config | head -60 || true
make defconfig
cp .config "$WORKDIR/final.config"
echo "--- 最终 .config 中选中的 luci 包（节选） ---"
grep -E '^CONFIG_PACKAGE_luci' .config | head -80 || true
echo "::endgroup::"

echo "::group::5/7 下载源码依赖包"
make download -j8
find dl -size -1024c -exec ls -l {} \; 2>/dev/null || true
find dl -size -1024c -exec rm -f {} \; 2>/dev/null || true
echo "::endgroup::"

echo "::group::6/7 编译固件"
set +e
make -j"$(nproc)" 2>&1 | tee "$LOG_FILE"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
  echo "::warning::并行编译失败（退出码 $RC），降级单线程 + V=s 重试"
  make -j1 V=s 2>&1 | tee -a "$LOG_FILE"
  RC=${PIPESTATUS[0]}
fi
set -e
if [ "$RC" -ne 0 ]; then
  echo "::error::编译失败（退出码 $RC），日志见 diagnose Artifact"
  exit "$RC"
fi
echo "::endgroup::"

echo "::group::7/7 整理产物"
mkdir -p "$OUT_DIR"
BIN_DIR="bin/targets/$TARGET/$SUBTARGET"
if [ ! -d "$BIN_DIR" ]; then
  echo "::error::未找到产物目录 $BIN_DIR，实际 bin/targets 内容："
  find bin/targets -maxdepth 2 -type d || true
  exit 1
fi
rm -rf "$BIN_DIR/packages"
cp -v "$BIN_DIR"/* "$OUT_DIR/" 2>/dev/null || true

# 仅保留常见固件/元数据文件，剔除源码包目录等无关内容
cd "$OUT_DIR"
find . -maxdepth 1 -type f ! -name "*.img" ! -name "*.img.gz" ! -name "*.bin" \
  ! -name "*.gz" ! -name "*.iso" ! -name "*.itb" ! -name "*.tar.gz" \
  ! -name "*.manifest" ! -name "*.json" ! -name "sha256sums" \
  -exec rm -f {} \; 2>/dev/null || true

# 生成 SHA256 校验
find . -maxdepth 1 -type f \( -name "*.img" -o -name "*.img.gz" -o -name "*.bin" \
  -o -name "*.gz" -o -name "*.iso" -o -name "*.itb" -o -name "*.tar.gz" \) -print0 | xargs -0 -r sha256sum > sha256sums.txt

# 写入构建元信息
cat > build-info.json <<EOF
{
  "build_id": "$BUILD_ID",
  "build_name": "$BUILD_NAME",
  "source_repo": "$SOURCE_REPO",
  "source_branch": "$SOURCE_BRANCH",
  "source_commit": "$(cd "$BUILD_DIR" && git rev-parse HEAD)",
  "target": "$TARGET",
  "subtarget": "$SUBTARGET",
  "profile": "$PROFILE",
  "plugins": "$PLUGINS",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "最终固件清单："
ls -lh "$OUT_DIR"
FILE_COUNT=$(find "$OUT_DIR" -maxdepth 1 -type f | wc -l)
echo "产物文件数: $FILE_COUNT"
[ "$FILE_COUNT" -gt 1 ] || { echo "::error::产物目录为空"; exit 1; }
echo "::endgroup::"

echo "✅ 构建完成，产物位于 $OUT_DIR"
