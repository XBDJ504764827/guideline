#!/usr/bin/env bash
# guideline 编译脚本
#
# 用法：
#   ./build.sh setup  首次：下载 SourceMod 1.11 编译器 + GOKZ 编译依赖 include
#   ./build.sh        编译（自动准备 include：优先本地 include/，否则从 gokz 仓库拉取到 .deps/）
#
# 环境变量：
#   SM_DIR             SourceMod 1.11 解压目录（默认项目下 .sm111/）
#   SPCOMP             spcomp 路径（默认 $SM_DIR/addons/sourcemod/scripting/spcomp64）
#   GOKZ_REPO_URL      GOKZ 源码仓库（默认 https://github.com/kzglobalteam/gokz）
set -euo pipefail
cd "$(dirname "$0")"

SM_DIR="${SM_DIR:-$(pwd)/.sm111}"
SPCOMP="${SPCOMP:-$SM_DIR/addons/sourcemod/scripting/spcomp64}"
GOKZ_REPO_URL="${GOKZ_REPO_URL:-https://github.com/kzglobalteam/gokz}"
DEPS_INCLUDE="$(pwd)/.deps/gokz-include"

if [[ "${1:-}" == "setup" ]]; then
  echo "Downloading SourceMod 1.11 (latest git build)..."
  mkdir -p "$SM_DIR"
  url="$(curl -s https://sm.alliedmods.net/smdrop/1.11/ | grep -o 'sourcemod-1.11[^"]*-linux.tar.gz' | sort -V | tail -n1)"
  curl -sL -o /tmp/sm111.tar.gz "https://sm.alliedmods.net/smdrop/1.11/$url"
  tar xzf /tmp/sm111.tar.gz -C "$SM_DIR"
  chmod +x "$SM_DIR/addons/sourcemod/scripting/spcomp"* 2>/dev/null || true
  rm -f /tmp/sm111.tar.gz
  echo "SourceMod extracted to $SM_DIR"
  ls -lh "$SM_DIR/addons/sourcemod/scripting/spcomp"* 2>&1 | head -n 5 || true
  exec "$0" deps
fi

if [[ "${1:-}" == "deps" ]]; then
  echo "Fetching GOKZ include dependencies..."
  rm -rf .deps
  mkdir -p .deps
  git clone --depth 1 --branch master "$GOKZ_REPO_URL" .deps/gokz
  cp -r .deps/gokz/addons/sourcemod/scripting/include "$DEPS_INCLUDE"
  rm -rf .deps/gokz
  echo "Includes ready at $DEPS_INCLUDE"
  exit 0
fi

# Robust spcomp lookup: prefer spcomp64 (32-bit spcomp fails on ubuntu-24.04 without i386 ld)
if [[ ! -x "$SPCOMP" ]]; then
  for cand in \
    "$SM_DIR/addons/sourcemod/scripting/spcomp64" \
    "$SM_DIR/sourcemod/scripting/spcomp64" \
    "$SM_DIR/addons/sourcemod/scripting/spcomp" \
    "$SM_DIR/sourcemod/scripting/spcomp"; do
    if [[ -x "$cand" ]]; then SPCOMP="$cand"; break; fi
  done
fi
if [[ ! -x "$SPCOMP" ]]; then
  echo "spcomp not found: $SPCOMP (also tried fallbacks under \$SM_DIR=$SM_DIR)"
  echo "Run './build.sh setup' first, or set SM_DIR/SPCOMP."
  ls -R "$SM_DIR" 2>&1 | head -n 100 || true
  exit 1
fi

# 编译依赖 include：项目 include + GOKZ 外部 include 均需加入
INC_PATHS=()
if [ -d "addons/sourcemod/scripting/include" ]; then
  INC_PATHS+=(-i=addons/sourcemod/scripting/include)
fi
if [ ! -d "$DEPS_INCLUDE" ]; then
  "$0" deps
fi
if [ -d "$DEPS_INCLUDE" ]; then
  INC_PATHS+=(-i="$DEPS_INCLUDE")
fi
if [ ${#INC_PATHS[@]} -eq 0 ]; then
  echo "No include paths found (neither addons/sourcemod/scripting/include nor $DEPS_INCLUDE)"
  exit 1
fi

mkdir -p addons/sourcemod/plugins

# Resolve SM include dir (support both layouts)
SM_INCLUDE="$SM_DIR/addons/sourcemod/scripting/include"
if [[ ! -d "$SM_INCLUDE" ]] && [[ -d "$SM_DIR/sourcemod/scripting/include" ]]; then
  SM_INCLUDE="$SM_DIR/sourcemod/scripting/include"
fi

# Strict mode: -E warnings-as-errors (PR/release CI uses STRICT=1)
STRICT_FLAGS=()
if [[ "${STRICT:-0}" == "1" ]]; then
  STRICT_FLAGS=(-E)
fi

"$SPCOMP" addons/sourcemod/scripting/guideline.sp \
  "${INC_PATHS[@]}" \
  -i="$SM_INCLUDE" \
  "${STRICT_FLAGS[@]}" \
  -o=addons/sourcemod/plugins/guideline.smx

echo "OK: addons/sourcemod/plugins/guideline.smx"
