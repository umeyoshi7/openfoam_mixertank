#!/bin/bash
#------------------------------------------------------------------------------
# upload_case.sh: OpenFOAM ケースファイルを GCS にアップロード
#
# 使い方:
#   source gcp/.env && bash gcp/upload_case.sh
#
# アップロード先:
#   gs://${BUCKET}/cases/LK-1_HD0.45/       (polyMesh 実体を含む完全なケース)
#   gs://${BUCKET}/cases/LK-1_HD0.45_MRF/   (polyMesh シンボリックリンクを除外)
#
# 除外するもの:
#   - processor*/ (並列分割結果)
#   - log.* (ログファイル)
#   - [0-9]*/ (計算済みタイムディレクトリ)
#   - 0.backup/, 0.orig/ (バックアップ)
#   - constant/polyMesh (MRF側のシンボリックリンク、実体は LK-1_HD0.45 側)
#   - postProcessing/ (中間結果)
#------------------------------------------------------------------------------
set -euo pipefail

: "${BUCKET:?環境変数 BUCKET が設定されていません}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRANSIENT_DIR="${REPO_ROOT}/LK-1_HD0.45"
MRF_DIR="${REPO_ROOT}/LK-1_HD0.45_MRF"

# 共通除外パターン (rsync の -x オプションは Python regex)
COMMON_EXCLUDE="processor[0-9]+/.*|log\.[^/]+$|0\.[a-z]+/.*|postProcessing/.*"
TRANSIENT_EXCLUDE="${COMMON_EXCLUDE}|[0-9]+(\.[0-9]+e[+-][0-9]+)?/[^/]+$"

echo "========================================"
echo "  GCS へケースファイルをアップロード"
echo "  バケット: gs://${BUCKET}"
echo "========================================"

# ---------------------------------------------------------------------------
# 1. LK-1_HD0.45 (pimpleFoam ケース、polyMesh 実体を含む)
# ---------------------------------------------------------------------------
echo ""
echo "[1/2] LK-1_HD0.45 をアップロード (polyMesh 含む)"
echo "  ソース: ${TRANSIENT_DIR}/"
echo "  宛先  : gs://${BUCKET}/cases/LK-1_HD0.45/"

gsutil -m rsync -r -d \
    -x "${TRANSIENT_EXCLUDE}" \
    "${TRANSIENT_DIR}/" \
    "gs://${BUCKET}/cases/LK-1_HD0.45/"

echo "  完了"

# ---------------------------------------------------------------------------
# 2. LK-1_HD0.45_MRF (simpleFoam + MRF ケース、polyMesh symlink を除外)
# ---------------------------------------------------------------------------
echo ""
echo "[2/2] LK-1_HD0.45_MRF をアップロード (constant/polyMesh は除外)"
echo "  ソース: ${MRF_DIR}/"
echo "  宛先  : gs://${BUCKET}/cases/LK-1_HD0.45_MRF/"

MRF_EXCLUDE="${COMMON_EXCLUDE}|constant/polyMesh(/.*)?$|[0-9]+/[^/]+$"

gsutil -m rsync -r -d \
    -x "${MRF_EXCLUDE}" \
    "${MRF_DIR}/" \
    "gs://${BUCKET}/cases/LK-1_HD0.45_MRF/"

echo "  完了"

echo ""
echo "========================================"
echo "  アップロード完了"
echo "  確認: gsutil ls gs://${BUCKET}/cases/"
echo "========================================"
