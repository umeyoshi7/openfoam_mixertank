#!/bin/bash
#------------------------------------------------------------------------------
# entrypoint_mesh.sh: Vertex AI Custom Job エントリポイント（メッシュ生成）
#
# ワークフロー:
#   1. GCS からケースファイルをダウンロード
#   2. OpenFOAM 環境読み込み
#   3. blockMesh
#   4. surfaceFeatureExtract
#   5. 0/ を 0.mesh/ で置換後 decomposePar+snappyHexMesh（並列）+reconstructPar
#   6. faceZones 存在確認（createBaffles の前提）
#   7. createBaffles（AMI1/AMI2 パッチ生成）
#   8. createNonConformalCouples（AMI1/AMI2 → NCC 変換）
#   9. checkMesh
#  10. polyMesh + fvMesh を GCS へアップロード
#
# 環境変数:
#   GCS_BUCKET        GCS バケット名 (必須)
#   NCORES            MPI コア数 (デフォルト: 4)
#   GCS_MESH_PREFIX   メッシュ出力先プレフィックス (デフォルト: mesh)
#   CASE_NAME         ケース名 (デフォルト: LKHD045)
#------------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# 環境変数のデフォルト値設定
# ---------------------------------------------------------------------------
GCS_BUCKET="${GCS_BUCKET:?ERROR: 環境変数 GCS_BUCKET が設定されていません}"
NCORES="${NCORES:-4}"
GCS_MESH_PREFIX="${GCS_MESH_PREFIX:-mesh}"
CASE_NAME="${CASE_NAME:-LKHD045}"
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
# OpenFOAM bashrc は内部で未設定変数を参照したり非ゼロ終了するコマンドを含む。
# source 中だけ厳格モードを一時解除し、true で $? をリセットしてから再有効化する。
set +euo pipefail
# shellcheck disable=SC1091
source /opt/openfoam11/etc/bashrc
true  # $? を 0 にリセットしてから set -e を再有効化
set -euo pipefail

if [ -z "${WM_PROJECT_VERSION:-}" ]; then
    echo "ERROR: OpenFOAM 環境の読み込みに失敗しました (WM_PROJECT_VERSION が未設定)"
    exit 1
fi
echo "  OpenFOAM: ${WM_PROJECT}-${WM_PROJECT_VERSION}"

# shellcheck disable=SC1091
. "${WM_PROJECT_DIR}/bin/tools/RunFunctions"

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

if [ ! -f "constant/polyMesh/faces" ]; then
    echo "ERROR: blockMesh が constant/polyMesh/faces を生成しませんでした"
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
# Step 5: snappyHexMesh（並列）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5] snappyHexMesh 実行 (NCORES=${NCORES})"
cd "${CASE_DIR}"
foamDictionary \
    -entry numberOfSubdomains -set "${NCORES}" \
    system/decomposeParDict

# CRITICAL: decomposePar の前に 0/ を 0.mesh/ で置換する。
# blockMesh が生成するパッチ (allBoundary, top) と 0/ のパッチ
# (reactor, impeller, AMI1, AMI2 等) が不整合を起こし decomposePar が
# エラーになるため、AMI なしの最小 BC セット 0.mesh/ を使用する。
rm -rf 0/
cp -r 0.mesh/ 0/

decomposePar -force 2>&1 | tee log.decomposePar
# --oversubscribe: Vertex AI の VM で OpenMPI スロット不足エラーを回避
mpirun --allow-run-as-root --oversubscribe -np "${NCORES}" \
    snappyHexMesh -parallel -overwrite 2>&1 | tee log.snappyHexMesh

# OF11 では reconstructPar -constant で constant/polyMesh/ にメッシュを再構築
# (reconstructParMesh ではなく reconstructPar を使用)
reconstructPar -constant 2>&1 | tee log.reconstructPar

# faceZones フォールバック: reconstructPar が faceZones を含まないケースに対応
if [ ! -f "constant/polyMesh/faceZones" ]; then
    echo "  reconstructPar 後に faceZones が見当たらない、フォールバックを試みます..."
    # Fallback 1: processor0/constant/polyMesh (-overwrite で直接書き込まれた場合)
    if [ -f "processor0/constant/polyMesh/faceZones" ]; then
        echo "  processor0/constant/polyMesh/ からコピー"
        cp "processor0/constant/polyMesh/faceZones" "constant/polyMesh/"
        [ -f "processor0/constant/polyMesh/cellZones" ] && \
            cp "processor0/constant/polyMesh/cellZones" "constant/polyMesh/"
    fi
    # Fallback 2: タイムディレクトリに書かれた場合
    if [ ! -f "constant/polyMesh/faceZones" ]; then
        PROC_ZONE=$(ls processor0/[0-9]*/polyMesh/faceZones 2>/dev/null | tail -1)
        if [ -n "${PROC_ZONE}" ]; then
            ZONE_TIME=$(echo "${PROC_ZONE}" | cut -d'/' -f2)
            echo "  processor0/${ZONE_TIME}/polyMesh/ からコピー (time=${ZONE_TIME})"
            cp "processor0/${ZONE_TIME}/polyMesh/faceZones" "constant/polyMesh/"
            [ -f "processor0/${ZONE_TIME}/polyMesh/cellZones" ] && \
                cp "processor0/${ZONE_TIME}/polyMesh/cellZones" "constant/polyMesh/"
        fi
    fi
fi

rm -rf processor[0-9]*
echo "  snappyHexMesh 完了"

# ---------------------------------------------------------------------------
# Step 6: faceZones 存在確認（createBaffles の前提）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6] faceZones 存在確認"
if [ ! -f "constant/polyMesh/faceZones" ]; then
    echo "ERROR: constant/polyMesh/faceZones が存在しません"
    echo "  snappyHexMesh が rotating faceZone を生成しなかった可能性があります"
    echo "  log.snappyHexMesh で 'rotating' faceZone の作成ログを確認してください"
    exit 1
fi
echo "  faceZones 確認 OK"

# ---------------------------------------------------------------------------
# Step 7: createBaffles（AMI1/AMI2 パッチ生成）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 7] createBaffles 実行"
cd "${CASE_DIR}"
createBaffles -overwrite 2>&1 | tee log.createBaffles
echo "  createBaffles 完了"

# ---------------------------------------------------------------------------
# Step 8: createNonConformalCouples（AMI1/AMI2 → NCC 変換）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 8] createNonConformalCouples 実行"
cd "${CASE_DIR}"
createNonConformalCouples -overwrite AMI1 AMI2 2>&1 | tee log.createNonConformalCouples
echo "  createNonConformalCouples 完了"

# ---------------------------------------------------------------------------
# Step 9: checkMesh（メッシュ品質検証）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 9] checkMesh 実行"
cd "${CASE_DIR}"
checkMesh 2>&1 | tee log.checkMesh

if grep -q "FAILED" log.checkMesh; then
    echo "ERROR: checkMesh が FAILED を報告しました。メッシュ品質を確認してください"
    grep -A2 "FAILED" log.checkMesh
    exit 1
fi
echo "  checkMesh 完了（問題なし）"

# ---------------------------------------------------------------------------
# Step 10: polyMesh + fvMesh を GCS へアップロード
# ---------------------------------------------------------------------------
# constant/polyMesh/: メッシュ本体 (faces, points, boundary, faceZones 等)
# constant/fvMesh/:   NCC スティッチャー用データ (polyFaces)
#                     createNonConformalCouples が生成。ソルバーに必要。
# ---------------------------------------------------------------------------
echo ""
echo "[Step 10] polyMesh + fvMesh を GCS へアップロード"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GCS_MESH_DEST="gs://${GCS_BUCKET}/${GCS_MESH_PREFIX}/mesh_${TIMESTAMP}"
echo "  宛先: ${GCS_MESH_DEST}/"

gsutil -m cp -r \
    "${CASE_DIR}/constant/polyMesh/" \
    "${GCS_MESH_DEST}/polyMesh/"

# createNonConformalCouples が生成した fvMesh/polyFaces もアップロード
if [ -d "${CASE_DIR}/constant/fvMesh" ]; then
    gsutil -m cp -r \
        "${CASE_DIR}/constant/fvMesh/" \
        "${GCS_MESH_DEST}/fvMesh/"
fi

gsutil -m cp \
    "${CASE_DIR}/log."* \
    "${GCS_MESH_DEST}/logs/" 2>/dev/null || true

printf '%s/\n' "${GCS_MESH_DEST}" | gsutil cp - \
    "gs://${GCS_BUCKET}/${GCS_MESH_PREFIX}/latest.txt"

echo "  アップロード完了: ${GCS_MESH_DEST}/"

echo ""
echo "========================================"
echo "  メッシュ生成ジョブ完了"
echo "  メッシュ: ${GCS_MESH_DEST}/"
echo "========================================"
