#!/bin/bash
#------------------------------------------------------------------------------
# entrypoint_mesh.sh: Vertex AI Custom Job エントリポイント（メッシュ生成）
#
# ワークフロー:
#   1. GCS からケースファイルをダウンロード
#   2. OpenFOAM 環境読み込み
#   3. blockMesh (背景 hex メッシュ生成)
#   4. surfaceFeatureExtract (.eMesh が未存在の場合のみ)
#   5. snappyHexMesh -overwrite (STL に沿ったリファインメント)
#   6. createBaffles -overwrite (AMI パッチ作成)
#   7. 生成した polyMesh を GCS へアップロード
#
# 環境変数:
#   GCS_BUCKET          GCS バケット名 (必須)
#   NCORES              MPI コア数 (デフォルト: 4)
#   GCS_MESH_PREFIX     メッシュの GCS プレフィックス (デフォルト: mesh)
#------------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# 環境変数のデフォルト値設定
# ---------------------------------------------------------------------------
GCS_BUCKET="${GCS_BUCKET:?環境変数 GCS_BUCKET が設定されていません}"
NCORES="${NCORES:-4}"
GCS_MESH_PREFIX="${GCS_MESH_PREFIX:-mesh}"
WORKSPACE="/workspace"
CASE_DIR="${WORKSPACE}/LK-1_HD0.45"

echo "========================================"
echo "  OpenFOAM Mesh Generation Job"
echo "  バケット    : gs://${GCS_BUCKET}"
echo "  コア数      : ${NCORES}"
echo "  メッシュ出力: ${GCS_MESH_PREFIX}"
echo "  作業DIR     : ${WORKSPACE}"
echo "========================================"

# ---------------------------------------------------------------------------
# Step 1: GCS からケースファイルをダウンロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 1] GCS からケースファイルをダウンロード"

gsutil -m cp -r "gs://${GCS_BUCKET}/cases/LK-1_HD0.45" "${WORKSPACE}/"

echo "  ダウンロード完了"

# ---------------------------------------------------------------------------
# Step 2: OpenFOAM 環境読み込み
# ---------------------------------------------------------------------------
echo ""
echo "[Step 2] OpenFOAM 環境読み込み"
# shellcheck disable=SC1091
source /opt/openfoam11/etc/bashrc
echo "  OpenFOAM: ${WM_PROJECT}-${WM_PROJECT_VERSION}"

# ---------------------------------------------------------------------------
# Step 3: blockMesh — 背景 hex メッシュ生成
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] blockMesh — 背景 hex メッシュ生成"
cd "${CASE_DIR}"
blockMesh 2>&1 | tee log.blockMesh
echo "  blockMesh 完了"

# ---------------------------------------------------------------------------
# Step 4: surfaceFeatureExtract — フィーチャーエッジ抽出
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] surfaceFeatureExtract — フィーチャーエッジ抽出"
cd "${CASE_DIR}"

# .eMesh ファイルが全て揃っている場合はスキップ
_emesh_ok=true
for _stl in reactor_HD0.45 impeller_HD0.45 baffle_HD0.45 shaft_HD0.45 rotation_HD0.45; do
    if [ ! -f "${CASE_DIR}/constant/triSurface/${_stl}.eMesh" ]; then
        _emesh_ok=false
        break
    fi
done

if [ "${_emesh_ok}" = "false" ]; then
    echo "  .eMesh ファイルが未検出 — surfaceFeatureExtract を実行"
    surfaceFeatureExtract 2>&1 | tee log.surfaceFeatureExtract
    echo "  surfaceFeatureExtract 完了"
else
    echo "  .eMesh ファイル確認済み — surfaceFeatureExtract をスキップ"
fi

# ---------------------------------------------------------------------------
# Step 5: snappyHexMesh — STL に沿ったリファインメント
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5] snappyHexMesh — メッシュリファインメント"
cd "${CASE_DIR}"

# decomposeParDict を NCORES に設定
foamDictionary \
    -entry numberOfSubdomains -set "${NCORES}" \
    "${CASE_DIR}/system/decomposeParDict"

if [ "${NCORES}" -gt 1 ]; then
    decomposePar 2>&1 | tee log.decomposePar_mesh
    mpirun --allow-run-as-root -np "${NCORES}" \
        snappyHexMesh -parallel -overwrite 2>&1 | tee log.snappyHexMesh
    reconstructParMesh -constant 2>&1 | tee log.reconstructParMesh
    rm -rf "${CASE_DIR}/processor"[0-9]*
else
    snappyHexMesh -overwrite 2>&1 | tee log.snappyHexMesh
fi

echo "  snappyHexMesh 完了"

# ---------------------------------------------------------------------------
# Step 6: createBaffles — AMI パッチ作成
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6] createBaffles — AMI1/AMI2 パッチ作成"
cd "${CASE_DIR}"
createBaffles -overwrite 2>&1 | tee log.createBaffles
echo "  createBaffles 完了"

# ---------------------------------------------------------------------------
# Step 7: 生成した polyMesh を GCS へアップロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 7] polyMesh を GCS へアップロード"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GCS_MESH_DEST="gs://${GCS_BUCKET}/${GCS_MESH_PREFIX}/LK-1_HD0.45_${TIMESTAMP}"
echo "  宛先: ${GCS_MESH_DEST}/"

gsutil -m cp -r \
    "${CASE_DIR}/constant/polyMesh" \
    "${GCS_MESH_DEST}/"

# メッシュ生成ログも保存
gsutil -m cp \
    "${CASE_DIR}/log."* \
    "${GCS_MESH_DEST}/logs/" 2>/dev/null || true

# 最新メッシュパスを記録
echo "${GCS_MESH_DEST}/polyMesh/" | gsutil cp - \
    "gs://${GCS_BUCKET}/${GCS_MESH_PREFIX}/latest.txt"

echo "  アップロード完了: ${GCS_MESH_DEST}/"

echo ""
echo "========================================"
echo "  メッシュ生成ジョブ完了"
echo "  polyMesh: ${GCS_MESH_DEST}/polyMesh/"
echo "========================================"
