#!/usr/bin/env bash
# File: scripts/convert_chs_eng.sh
#
# Purpose / 脚本目的:
#   - Call srt-tools AWK scripts to generate:            调用 srt-tools 的 AWK 脚本以生成:
#       <basename>.Eng&Chs.srt   (via srt_zh_en_swap.awk)     通过 srt_zh_en_swap.awk 生成 <basename>.Eng&Chs.srt
#       <basename>.Chs.srt       (via srt_zh_only + wrap)     通过 srt_zh_only.awk + srt_zh_wrap.awk 生成 <basename>.Chs.srt
#   - Compare with existing files and only commit if changed. 比较生成文件与现有文件，仅在有变更时提交
#   - Commit & push back to the source repository.        提交并强制推送回源仓库
#
# Usage / 用法:
#   ./convert_chs_eng.sh <source_checkout_path> <source_file> <target_dir> <tools_checkout_path> <source_ref> [split_threshold] [bracket_factor]
#
# 参数说明 / Arguments:
#   1: source_checkout_path  -> 调用仓库的检出目录 (e.g., "source")
#   2: source_file           -> 源字幕文件路径 (e.g., "web/web.srt")
#   3: target_dir            -> 输出目录 (e.g., "web")
#   4: tools_checkout_path   -> srt-tools 仓库目录 (e.g., "srt-tools")
#   5: source_ref            -> 完整的 Git 引用 (e.g., refs/heads/main)
#   6: split_threshold       -> (可选) wrap 脚本换行阈值
#   7: bracket_factor        -> (可选) wrap 脚本括号因子
#
set -euo pipefail
IFS=$'\n\t'

# ----------------------------
# Validate args / 参数校验
# ----------------------------
if [ "$#" -lt 5 ]; then
  echo "Usage: $0 <source_checkout_path> <source_file> <target_dir> <tools_checkout_path> <source_ref> [split_threshold] [bracket_factor]"
  echo "错误: 参数数量不足 / Error: not enough arguments" >&2
  exit 2
fi

SRC_CHECKOUT="$1"        # 源仓库检出目录 / Source checkout path
SRC_FILE_REL="$2"        # 源字幕文件 / Source file relative path
TARGET_DIR_REL="$3"      # 目标输出目录 / Target output dir
TOOLS_PATH="$4"          # srt-tools 仓库目录 / srt-tools repo path
SOURCE_REF="$5"          # Git 引用 (分支或 tag) / Source ref
SPLIT_THRESHOLD="${6:-20}"   # 换行阈值 / Wrap threshold
BRACKET_FACTOR="${7:-2}"     # 括号因子 / Bracket factor

# Commit author info / 提交者信息
GIT_AUTHOR_NAME="MontageSubsBot"
GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

# 临时工作目录 / Temporary workspace
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# 输出描述文件，用于传回 GitHub Outputs
# Output descriptor file for workflow outputs
OUT_DESC="${RUNNER_TEMP:-/tmp}/srt_convert_created"
: > "$OUT_DESC"

# 源文件绝对路径 / Source absolute path
SRC_PATH="${SRC_CHECKOUT}/${SRC_FILE_REL}"

# ----------------------------
# Sanity checks / 基本检查
# ----------------------------
if [ ! -d "${SRC_CHECKOUT}" ]; then
  echo "ERROR: source checkout path does not exist / 源仓库目录不存在: ${SRC_CHECKOUT}" >&2
  exit 3
fi

if [ ! -f "${SRC_PATH}" ]; then
  echo "ERROR: source srt file not found / 源字幕文件未找到: ${SRC_PATH}" >&2
  exit 4
fi

if [ ! -d "${TOOLS_PATH}" ]; then
  echo "ERROR: srt-tools checkout not found / srt-tools 仓库未找到: ${TOOLS_PATH}" >&2
  exit 5
fi

AWK_SWAP="${TOOLS_PATH}/scripts/awk/srt_zh_en_swap.awk"
AWK_ZH_ONLY="${TOOLS_PATH}/scripts/awk/srt_zh_only.awk"
AWK_WRAP="${TOOLS_PATH}/scripts/awk/srt_zh_wrap.awk"

for f in "$AWK_SWAP" "$AWK_ZH_ONLY" "$AWK_WRAP"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing AWK script / 缺少 AWK 脚本: $f" >&2
    exit 6
  fi
done

if ! command -v awk >/dev/null 2>&1; then
  echo "ERROR: awk not found / 系统缺少 awk" >&2
  exit 7
fi

# ----------------------------
# File naming / 文件命名
# ----------------------------
fname="$(basename -- "$SRC_FILE_REL")"
base="${fname%.srt}"
DEST_DIR="${SRC_CHECKOUT}/${TARGET_DIR_REL}"
mkdir -p "$DEST_DIR"

DEST_ENG="${DEST_DIR}/${base}.Eng&Chs.srt"
DEST_CHS="${DEST_DIR}/${base}.Chs.srt"

TMP_ENG="${WORKDIR}/${base}.Eng&Chs.srt.tmp"
TMP_CHS_INTER="${WORKDIR}/${base}.Chs.tmp.srt"
TMP_CHS="${WORKDIR}/${base}.Chs.srt.tmp"

# ----------------------------
# Run AWK scripts / 运行 AWK 脚本
# ----------------------------
echo "[info] Generate Eng&Chs / 生成 Eng&Chs"
awk -f "$AWK_SWAP" "$SRC_PATH" > "$TMP_ENG"

echo "[info] Generate Chs-only intermediate / 生成仅中文临时文件"
awk -f "$AWK_ZH_ONLY" "$SRC_PATH" > "$TMP_CHS_INTER"

echo "[info] Wrap Chs / 中文换行处理"
awk -v SPLIT_THRESHOLD="$SPLIT_THRESHOLD" -v BRACKET_FACTOR="$BRACKET_FACTOR" \
    -f "$AWK_WRAP" "$TMP_CHS_INTER" > "$TMP_CHS"

# ----------------------------
# Verify outputs / 验证输出
# ----------------------------
if [ ! -s "$TMP_ENG" ]; then
  echo "ERROR: Eng&Chs empty / Eng&Chs 文件为空" >&2
  exit 8
fi
if [ ! -s "$TMP_CHS" ]; then
  echo "ERROR: Chs empty / Chs 文件为空" >&2
  exit 9
fi

# ----------------------------
# Copy only if changed / 仅在文件有变化时复制
# ----------------------------
changed_files=()
copy_if_diff() {
  src="$1"; dst="$2"
  mkdir -p "$(dirname -- "$dst")"
  if [ -f "$dst" ]; then
    if cmp -s -- "$src" "$dst"; then
      echo "[info] No change / 无变化: $(basename "$dst")"
      return 1
    else
      mv -f -- "$src" "$dst"
      changed_files+=("$dst")
      echo "[info] Updated / 已更新: $dst"
      return 0
    fi
  else
    mv -f -- "$src" "$dst"
    changed_files+=("$dst")
    echo "[info] Created / 已创建: $dst"
    return 0
  fi
}

copy_if_diff "$TMP_ENG" "$DEST_ENG" || true
copy_if_diff "$TMP_CHS" "$DEST_CHS" || true

# ----------------------------
# Commit & push / 提交并推送
# ----------------------------
if [ "${#changed_files[@]}" -eq 0 ]; then
  echo "[info] Nothing to commit / 无需提交"
  echo "eng_path=" > "$OUT_DESC"
  echo "chs_path=" >> "$OUT_DESC"
  exit 0
fi

cd "$SRC_CHECKOUT"
git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"
git add -- "${changed_files[@]}"

COMMIT_MSG="update: ci: regenerate Eng&Chs.srt and Chs.srt from ${SRC_FILE_REL}"
git commit -m "$COMMIT_MSG" || {
  echo "[info] No commit made / 无需提交"
  exit 0
}

branch=""
if [[ "${SOURCE_REF}" == refs/heads/* ]]; then
  branch="${SOURCE_REF#refs/heads/}"
else
  branch="$(git rev-parse --abbrev-ref HEAD || true)"
fi

if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  echo "ERROR: Cannot determine branch / 无法识别分支: ${SOURCE_REF}" >&2
  exit 10
fi

echo "[info] Force pushing / 强制推送: ${branch}"
git push -f origin "HEAD:${branch}"

# ----------------------------
# Write outputs / 写出输出路径
# ----------------------------
rel_eng="${TARGET_DIR_REL%/}/${base}.Eng&Chs.srt"
rel_chs="${TARGET_DIR_REL%/}/${base}.Chs.srt"

echo "eng_path=${rel_eng}" > "$OUT_DESC"
echo "chs_path=${rel_chs}" >> "$OUT_DESC"

echo "[info] Done. Outputs / 完成，输出文件:"
echo "  - ${rel_eng}"
echo "  - ${rel_chs}"
