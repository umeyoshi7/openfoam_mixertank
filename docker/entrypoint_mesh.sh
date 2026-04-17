#!/bin/bash
#------------------------------------------------------------------------------
# entrypoint_mesh.sh: Vertex AI Custom Job エントリポイント（メッシュ生成）
#
# ワークフロー:
#   1. GCS からケースファイルをダウンロード
#   2. OpenFOAM 環境読み込み
#   3. blockMesh
#   4. surfaceFeatureExtract
#   5. 0/ を 0.mesh/ で置換後 decomposePar+snappyHexMesh（並列）
#        ※ blockMesh は allBoundary+top のみ生成。既存 0/ が reactor/impeller 等を
#           参照すると decomposePar がパッチ不整合でエラーになり停止するため、
#           AMI なしの最小 BC セット 0.mesh/ で置換してから実行する。
#   6. faceZones 存在確認（createBaffles の前提）
#   7. createBaffles（AMI1/AMI2 パッチ生成）
#   8. checkMesh
#   9. polyMesh を GCS へアップロード
#
# 環境変数:
#   GCS_BUCKET        GCS バケット名 (必須)
#   NCORES            MPI コア数 (デフォルト: 4)
#   GCS_MESH_PREFIX   メッシュ出力先プレフィックス (デフォルト: mesh)
#   CASE_NAME         ケース名 (デフォルト: LK-1_HD0.45)
#------------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# 環境変数のデフォルト値設定
# ---------------------------------------------------------------------------
GCS_BUCKET="${GCS_BUCKET:?ERROR: 環境変数 GCS_BUCKET が設定されていません}"
NCORES="${NCORES:-4}"
GCS_MESH_PREFIX="${GCS_MESH_PREFIX:-mesh}"
CASE_NAME="${CASE_NAME:-LK-1_HD0.45}"
WORKSPACE="/workspace"
CASE_DIR="${WORKSPACE}/${CASE_NAME}"

echo "========================================"
echo "  OpenFOAM Mesh Generation Job"
echo "  バケット  : gs://${GCS_BUCKET}"
echo "  コア数    : ${NCORES}"
echo "  ケース    : ${CASE_NAME}"
echo "  メッシュ先: gs://${GCS_BUCKET}/${GCS_MESH_PREFIX}/"
echo "========================================"

# ---------------------------------------------------------------------------
# Step 1: GCS からケースファイルをダウンロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 1] GCS からケースファイルをダウンロード"
gsutil -m cp -r "gs://${GCS_BUCKET}/cases/${CASE_NAME}" "${WORKSPACE}/"
echo "  ダウンロード完了"

# ---------------------------------------------------------------------------
# Step 2: OpenFOAM 環境読み込み
# ---------------------------------------------------------------------------
echo ""
echo "[Step 2] OpenFOAM 環境読み込み"
# OpenFOAM bashrc は内部で未設定変数を参照したり非ゼロ終了するコマンドを含むため、
# source 中だけ厳格モードを一時解除する。
set +euo pipefail
# shellcheck disable=SC1091
source /opt/openfoam11/etc/bashrc
set -euo pipefail

# WM_PROJECT_VERSION の確認 (set -u のもとで未設定なら即終了するため明示チェック)
if [ -z "${WM_PROJECT_VERSION:-}" ]; then
    echo "ERROR: OpenFOAM 環境の読み込みに失敗しました (WM_PROJECT_VERSION が未設定)"
    exit 1
fi
echo "  OpenFOAM: ${WM_PROJECT}-${WM_PROJECT_VERSION}"

# RunFunctions を明示的にロード (bashrc は環境変数のみセット、restore0Dir 等は含まない)
# shellcheck disable=SC1091
. "${WM_PROJECT_DIR}/bin/tools/RunFunctions"

# RunFunctions (restore0Dir 等) の可用性確認
if ! type restore0Dir > /dev/null 2>&1; then
    echo "ERROR: restore0Dir が使用できません (RunFunctions が未ロード)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: blockMesh
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] blockMesh 実行"
cd "${CASE_DIR}"
blockMesh 2>&1 | tee log.blockMesh

if [ ! -f "constant/fvMesh/faces" ]; then
    echo "ERROR: blockMesh が constant/fvMesh/faces を生成しませんでした"
    exit 1
fi
echo "  blockMesh 完了"

# ---------------------------------------------------------------------------
# Step 4: surfaceFeatureExtract
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] surfaceFeatureExtract 実行"
cd "${CASE_DIR}"
surfaceFeatureExtract 2>&1 | tee log.surfaceFeatureExtract
echo "  surfaceFeatureExtract 完了"

# ---------------------------------------------------------------------------
# Step 5: snappyHexMesh（並列対応）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5] snappyHexMesh 実行 (NCORES=${NCORES})"
cd "${CASE_DIR}"
foamDictionary \
    -entry numberOfSubdomains -set "${NCORES}" \
    system/decomposeParDict

# CRITICAL: 0/ を 0.mesh/ で置換してから decomposePar を実行する。
# blockMesh が生成するパッチ (allBoundary, top) と 0/ が参照するパッチ
# (reactor_HD0.45, impeller_HD0.45, AMI1, AMI2 等) が不整合を起こし、
# decomposePar がエラーになって snappyHexMesh が停止する。
# 0.mesh/ は snappyHexMesh 後のパッチ構成に合わせた最小 BC セット (AMI なし)。
rm -rf 0/
cp -r 0.mesh/ 0/

if [ "${NCORES}" -gt 1 ]; then
    decomposePar -force 2>&1 | tee log.decomposePar
    # --oversubscribe: Vertex AI の VM で OpenMPI スロット不足エラーを回避
    mpirun --allow-run-as-root --oversubscribe -np "${NCORES}" \
        snappyHexMesh -parallel -overwrite 2>&1 | tee log.snappyHexMesh
    # -constant: cellZones/faceZones を constant/fvMesh/ に書き込む
    #   (このフラグなしだと 0/ に書かれ createBaffles が失敗する)
    reconstructParMesh -constant 2>&1 | tee log.reconstructParMesh
    rm -rf processor[0-9]*
else
    snappyHexMesh -overwrite 2>&1 | tee log.snappyHexMesh
fi
echo "  snappyHexMesh 完了"

# ---------------------------------------------------------------------------
# Step 6: faceZones 存在確認（createBaffles の前提）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6] faceZones 存在確認"
if [ ! -f "constant/fvMesh/faceZones" ]; then
    echo "ERROR: constant/fvMesh/faceZones が存在しません"
    echo "  snappyHexMesh が rotating faceZone を生成しなかった可能性があります"
    echo "  snappyHexMeshDict の addLayers/refinementSurfaces の設定を確認してください"
    exit 1
fi
echo "  faceZones 確認 OK"

# ---------------------------------------------------------------------------
# Step 7: createBaffles（AMI パッチ生成）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 7] createBaffles 実行"
cd "${CASE_DIR}"
createBaffles -overwrite 2>&1 | tee log.createBaffles
echo "  createBaffles 完了"

# ---------------------------------------------------------------------------
# Step 8: checkMesh（メッシュ品質検証）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 8] checkMesh 実行"
cd "${CASE_DIR}"
checkMesh 2>&1 | tee log.checkMesh

if grep -q "FAILED" log.checkMesh; then
    echo "ERROR: checkMesh が FAILED を報告しました。メッシュ品質を確認してください"
    echo "  log.checkMesh の内容:"
    grep -A2 "FAILED" log.checkMesh
    exit 1
fi
echo "  checkMesh 完了（問題なし）"

# ---------------------------------------------------------------------------
# Step 9: fvMesh を GCS へアップロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 9] fvMesh を GCS へアップロード"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GCS_MESH_DEST="gs://${GCS_BUCKET}/${GCS_MESH_PREFIX}/fvMesh_${TIMESTAMP}"
echo "  宛先: ${GCS_MESH_DEST}/"

# fvMesh ディレクトリのみアップロード（ケース全体は不要）
gsutil -m cp -r \
    "${CASE_DIR}/constant/fvMesh/" \
    "${GCS_MESH_DEST}/"

# メッシュ生成ログをアップロード（デバッグ用）
gsutil -m cp \
    "${CASE_DIR}/log."* \
    "${GCS_MESH_DEST}/logs/" 2>/dev/null || true

# 最新メッシュパスを記録（ソルバージョブが GCS_MESH_PATH 未指定時に参照）
printf '%s/\n' "${GCS_MESH_DEST}" | gsutil cp - \
    "gs://${GCS_BUCKET}/${GCS_MESH_PREFIX}/latest.txt"

echo "  アップロード完了: ${GCS_MESH_DEST}/"

echo ""
echo "========================================"
echo "  メッシュ生成ジョブ完了"
echo "  メッシュ: ${GCS_MESH_DEST}/"
echo "========================================"
