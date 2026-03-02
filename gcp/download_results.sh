#!/bin/bash
#------------------------------------------------------------------------------
# download_results.sh: GCS から計算結果をローカルへダウンロード
#
# 使い方:
#   source gcp/.env && bash gcp/download_results.sh [RESULT_PATH]
#
#   RESULT_PATH: GCS 上の結果パス (省略時は latest.txt から自動取得)
#   例: bash gcp/download_results.sh gs://my-bucket/results/LK-1_HD0.45_20260302_120000/
#------------------------------------------------------------------------------
set -euo pipefail

: "${BUCKET:?環境変数 BUCKET が設定されていません}"
GCS_RESULT_PREFIX="${GCS_RESULT_PREFIX:-results}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_RESULTS_DIR="${REPO_ROOT}/results"

# 結果パスの決定
if [ -n "${1:-}" ]; then
    GCS_SRC="${1}"
else
    # latest.txt から最新結果パスを取得
    LATEST_FILE="gs://${BUCKET}/${GCS_RESULT_PREFIX}/latest.txt"
    echo "latest.txt から結果パスを取得中: ${LATEST_FILE}"
    GCS_SRC=$(gsutil cat "${LATEST_FILE}" 2>/dev/null | tr -d '[:space:]')
    if [ -z "${GCS_SRC}" ]; then
        echo "エラー: latest.txt が見つからないか空です。引数で結果パスを指定してください。"
        echo "  例: bash gcp/download_results.sh gs://${BUCKET}/${GCS_RESULT_PREFIX}/LK-1_HD0.45_20260302_120000/"
        exit 1
    fi
fi

# ローカル保存先ディレクトリ名を GCS パスから生成
RESULT_NAME=$(basename "${GCS_SRC%/}")
LOCAL_DEST="${LOCAL_RESULTS_DIR}/${RESULT_NAME}"

echo "========================================"
echo "  結果ダウンロード"
echo "  ソース: ${GCS_SRC}"
echo "  宛先  : ${LOCAL_DEST}/"
echo "========================================"

mkdir -p "${LOCAL_DEST}"

gsutil -m cp -r "${GCS_SRC}" "${LOCAL_RESULTS_DIR}/"

echo ""
echo "========================================"
echo "  ダウンロード完了"
echo "  ローカルパス: ${LOCAL_DEST}/"
echo "  確認コマンド:"
echo "    ls ${LOCAL_DEST}/"
echo "========================================"
