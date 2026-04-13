#!/bin/bash
#------------------------------------------------------------------------------
# entrypoint.sh: Vertex AI Custom Job エントリポイント
#
# フルワークフロー:
#   1. GCS からケースファイルをダウンロード
#   2. polyMesh シンボリックリンク再作成
#   3. NCORES に応じた decomposeParDict 書き換え
#   4. MRF simpleFoam (定常収束)
#   5. mapFields (MRF → pimpleFoam 初期値転写)
#   6. pimpleFoam (非定常計算)
#   7. 結果を GCS へアップロード
#
# 環境変数:
#   GCS_BUCKET          GCS バケット名 (必須)
#   NCORES              MPI コア数 (デフォルト: 4)
#   GCS_RESULT_PREFIX   結果の GCS プレフィックス (デフォルト: results)
#   MRF_END_TIME        MRF 計算の終了イテレーション数 (デフォルト: 3000)
#------------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# 環境変数のデフォルト値設定
# ---------------------------------------------------------------------------
GCS_BUCKET="${GCS_BUCKET:?環境変数 GCS_BUCKET が設定されていません}"
NCORES="${NCORES:-4}"
GCS_RESULT_PREFIX="${GCS_RESULT_PREFIX:-results}"
MRF_END_TIME="${MRF_END_TIME:-3000}"
WORKSPACE="/workspace"
MRF_DIR="${WORKSPACE}/LK-1_HD0.45_MRF"
TRANSIENT_DIR="${WORKSPACE}/LK-1_HD0.45"

echo "========================================"
echo "  OpenFOAM Vertex AI Custom Job"
echo "  バケット : gs://${GCS_BUCKET}"
echo "  コア数   : ${NCORES}"
echo "  作業DIR  : ${WORKSPACE}"
echo "========================================"

# ---------------------------------------------------------------------------
# Step 1: GCS からケースファイルをダウンロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 1] GCS からケースファイルをダウンロード"

gsutil -m cp -r "gs://${GCS_BUCKET}/cases/LK-1_HD0.45"     "${WORKSPACE}/"
gsutil -m cp -r "gs://${GCS_BUCKET}/cases/LK-1_HD0.45_MRF" "${WORKSPACE}/"

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
# Step 3: polyMesh シンボリックリンク再作成
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] polyMesh シンボリックリンク再作成"
mkdir -p "${MRF_DIR}/constant"
# GCS はシンボリックリンクを保持しないため、ここで再作成する
# リンクの位置 constant/polyMesh から見た相対パス: ../../LK-1_HD0.45/constant/polyMesh
ln -sf "../../LK-1_HD0.45/constant/polyMesh" "${MRF_DIR}/constant/polyMesh"
echo "  ${MRF_DIR}/constant/polyMesh -> ../../LK-1_HD0.45/constant/polyMesh"

# ---------------------------------------------------------------------------
# Step 4: decomposeParDict を NCORES で書き換え（両ケース）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] decomposeParDict を NCORES=${NCORES} に設定"
foamDictionary \
    -entry numberOfSubdomains -set "${NCORES}" \
    "${MRF_DIR}/system/decomposeParDict"
foamDictionary \
    -entry numberOfSubdomains -set "${NCORES}" \
    "${TRANSIENT_DIR}/system/decomposeParDict"
echo "  両ケースの numberOfSubdomains を ${NCORES} に設定"

# ---------------------------------------------------------------------------
# Step 5a: MRF simpleFoam (定常収束)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5a] MRF simpleFoam 実行 (endTime=${MRF_END_TIME})"
cd "${MRF_DIR}"

# 0/ を 0.orig/ からリセット
restore0Dir

# MRF_END_TIME 反映
foamDictionary -entry endTime -set "${MRF_END_TIME}" system/controlDict

# 並列計算
if [ "${NCORES}" -gt 1 ]; then
    decomposePar -force 2>&1 | tee log.decomposePar
    mpirun --allow-run-as-root -np "${NCORES}" simpleFoam -parallel 2>&1 | tee log.simpleFoam
    reconstructPar -latestTime 2>&1 | tee log.reconstructPar
else
    simpleFoam 2>&1 | tee log.simpleFoam
fi

echo "  MRF simpleFoam 完了"

# ---------------------------------------------------------------------------
# Step 5b: mapFields (MRF → pimpleFoam 初期値転写)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5b] mapFields: MRF → pimpleFoam"
cd "${MRF_DIR}"

LATEST_TIME=$(foamListTimes -latestTime | tail -1)
if [ -z "${LATEST_TIME}" ]; then
    echo "エラー: MRF の出力タイムディレクトリが見つかりません"
    exit 1
fi
echo "  最新タイム: ${LATEST_TIME}"

# 0/ をバックアップ
cp -r "${TRANSIENT_DIR}/0" "${TRANSIENT_DIR}/0.backup"

# フィールドマッピング (source=., target=LK-1_HD0.45)
mapFields \
    -consistent \
    -sourceTime "${LATEST_TIME}" \
    -case "${TRANSIENT_DIR}" \
    .

echo "  mapFields 完了"

# マッピング結果の確認
echo "  0/U internalField 確認:"
grep -A2 "^internalField" "${TRANSIENT_DIR}/0/U" | head -4

# ---------------------------------------------------------------------------
# Step 5c: pimpleFoam (非定常計算)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5c] pimpleFoam 実行"
cd "${TRANSIENT_DIR}"

# pimpleFoam が途中終了しても結果を GCS にアップロードするため
# このブロックのみ set -e を一時解除して終了コードを手動で捕捉する。
# PIMPLE_EXIT はブロック先頭で初期化し、decomposePar 等の前段処理が
# 失敗した場合でも set -u による「unbound variable」エラーを防ぐ。
PIMPLE_EXIT=1
set +e
if [ "${NCORES}" -gt 1 ]; then
    decomposePar -force 2>&1 | tee log.decomposePar
    mpirun --allow-run-as-root -np "${NCORES}" pimpleFoam -parallel 2>&1 | tee log.pimpleFoam
    PIMPLE_EXIT=${PIPESTATUS[0]}
    reconstructPar 2>&1 | tee log.reconstructPar
else
    pimpleFoam 2>&1 | tee log.pimpleFoam
    PIMPLE_EXIT=${PIPESTATUS[0]}
fi
set -e

echo "  pimpleFoam 完了 (exit: ${PIMPLE_EXIT})"

# ---------------------------------------------------------------------------
# Step 6: 結果を GCS へアップロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6] 結果を GCS へアップロード"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GCS_DEST="gs://${GCS_BUCKET}/${GCS_RESULT_PREFIX}/LK-1_HD0.45_${TIMESTAMP}"
echo "  宛先: ${GCS_DEST}/"

# processor* ディレクトリは容量節約のため除外 (reconstructPar 済み)
gsutil -m cp -r \
    -x "processor[0-9]*" \
    "${TRANSIENT_DIR}/" \
    "${GCS_DEST}/"

# MRF ログも保存
gsutil -m cp \
    "${MRF_DIR}/log."* \
    "${GCS_DEST}/mrf_logs/" 2>/dev/null || true

# 最新結果パスを記録
echo "${GCS_DEST}/" | gsutil cp - \
    "gs://${GCS_BUCKET}/${GCS_RESULT_PREFIX}/latest.txt"

echo "  アップロード完了: ${GCS_DEST}/"

echo ""
echo "========================================"
echo "  ジョブ完了"
echo "  結果: ${GCS_DEST}/"
echo "========================================"

exit "${PIMPLE_EXIT}"
