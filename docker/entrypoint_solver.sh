#!/bin/bash
#------------------------------------------------------------------------------
# entrypoint_solver.sh: Vertex AI Custom Job エントリポイント（ソルバー）
#
# ワークフロー:
#   1. GCS からケースファイルをダウンロード
#   2. OpenFOAM 環境読み込み
#   3. GCS から polyMesh をダウンロード（GCS_MESH_PATH または mesh/latest.txt 参照）
#   4. polyMesh シンボリックリンク再作成
#   5. decomposeParDict を NCORES に更新
#   6. MRF simpleFoam（定常収束）
#   7. mapFields（MRF → pimpleFoam 初期値転写）
#   8. pimpleFoam（非定常計算）
#   9. 結果を GCS へアップロード
#
# 環境変数:
#   GCS_BUCKET          GCS バケット名 (必須)
#   NCORES              MPI コア数 (デフォルト: 4)
#   GCS_RESULT_PREFIX   結果の GCS プレフィックス (デフォルト: results)
#   MRF_END_TIME        MRF 計算の終了イテレーション数 (デフォルト: 3000)
#   GCS_MESH_PATH       polyMesh の GCS パス (省略時: mesh/latest.txt から自動取得)
#------------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# 環境変数のデフォルト値設定
# ---------------------------------------------------------------------------
GCS_BUCKET="${GCS_BUCKET:?ERROR: 環境変数 GCS_BUCKET が設定されていません}"
NCORES="${NCORES:-4}"
GCS_RESULT_PREFIX="${GCS_RESULT_PREFIX:-results}"
MRF_END_TIME="${MRF_END_TIME:-3000}"
GCS_MESH_PATH="${GCS_MESH_PATH:-}"   # 省略時は mesh/latest.txt から取得
WORKSPACE="/workspace"
MRF_DIR="${WORKSPACE}/LK-1_HD0.45_MRF"
TRANSIENT_DIR="${WORKSPACE}/LK-1_HD0.45"

echo "========================================"
echo "  OpenFOAM Solver Job"
echo "  バケット   : gs://${GCS_BUCKET}"
echo "  コア数     : ${NCORES}"
echo "  MRF終了時刻: ${MRF_END_TIME}"
echo "  作業DIR    : ${WORKSPACE}"
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

# WM_PROJECT_VERSION の確認 (set -u のもとで未設定なら即終了するため明示チェック)
if [ -z "${WM_PROJECT_VERSION:-}" ]; then
    echo "ERROR: OpenFOAM 環境の読み込みに失敗しました (WM_PROJECT_VERSION が未設定)"
    exit 1
fi
echo "  OpenFOAM: ${WM_PROJECT}-${WM_PROJECT_VERSION}"

# RunFunctions (restore0Dir 等) の可用性確認
if ! type restore0Dir > /dev/null 2>&1; then
    echo "ERROR: restore0Dir が使用できません (RunFunctions が未ロード)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: GCS から polyMesh をダウンロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] polyMesh の解決とダウンロード"

# GCS_MESH_PATH が未指定の場合は mesh/latest.txt から取得
if [ -z "${GCS_MESH_PATH}" ]; then
    echo "  GCS_MESH_PATH 未設定 → gs://${GCS_BUCKET}/mesh/latest.txt から取得"
    GCS_MESH_PATH=$(gsutil cat "gs://${GCS_BUCKET}/mesh/latest.txt" 2>/dev/null \
        | tr -d '[:space:]')
fi
if [ -z "${GCS_MESH_PATH}" ]; then
    echo "ERROR: polyMesh パスを特定できません。"
    echo "  GCS_MESH_PATH 環境変数を設定するか、メッシュ生成ジョブを先に実行してください。"
    exit 1
fi
echo "  使用メッシュ: ${GCS_MESH_PATH}"

mkdir -p "${TRANSIENT_DIR}/constant/polyMesh"
gsutil -m cp -r "${GCS_MESH_PATH}*" "${TRANSIENT_DIR}/constant/polyMesh/"
echo "  polyMesh ダウンロード完了"

# ---------------------------------------------------------------------------
# Step 4: polyMesh シンボリックリンク再作成
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] polyMesh シンボリックリンク再作成"
mkdir -p "${MRF_DIR}/constant"
# GCS はシンボリックリンクを保存できないため、ダウンロード後に必ず再作成する。
# 既存ディレクトリ（GCS が実ディレクトリとして保存した場合）を削除してから ln -sf する。
rm -rf "${MRF_DIR}/constant/polyMesh"
ln -sf "../../LK-1_HD0.45/constant/polyMesh" "${MRF_DIR}/constant/polyMesh"
echo "  ${MRF_DIR}/constant/polyMesh -> ../../LK-1_HD0.45/constant/polyMesh"

# シンボリックリンクの解決確認
if [ ! -f "${MRF_DIR}/constant/polyMesh/faces" ]; then
    echo "ERROR: polyMesh シンボリックリンクが正しく解決されません"
    echo "  ${TRANSIENT_DIR}/constant/polyMesh/faces が存在するか確認してください"
    exit 1
fi
echo "  シンボリックリンク確認 OK"

# ---------------------------------------------------------------------------
# Step 5: decomposeParDict を NCORES で書き換え（両ケース）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5] decomposeParDict を NCORES=${NCORES} に設定"
foamDictionary \
    -entry numberOfSubdomains -set "${NCORES}" \
    "${MRF_DIR}/system/decomposeParDict"
foamDictionary \
    -entry numberOfSubdomains -set "${NCORES}" \
    "${TRANSIENT_DIR}/system/decomposeParDict"
echo "  両ケースの numberOfSubdomains を ${NCORES} に設定"

# ---------------------------------------------------------------------------
# Step 6a: MRF simpleFoam（定常収束）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6a] MRF simpleFoam 実行 (endTime=${MRF_END_TIME})"
cd "${MRF_DIR}"

restore0Dir
foamDictionary -entry endTime -set "${MRF_END_TIME}" system/controlDict

if [ "${NCORES}" -gt 1 ]; then
    decomposePar -force 2>&1 | tee log.decomposePar
    # --oversubscribe: Vertex AI の VM で OpenMPI スロット不足エラーを回避
    mpirun --allow-run-as-root --oversubscribe -np "${NCORES}" \
        simpleFoam -parallel 2>&1 | tee log.simpleFoam
    reconstructPar -latestTime 2>&1 | tee log.reconstructPar
    rm -rf processor[0-9]*
else
    simpleFoam 2>&1 | tee log.simpleFoam
fi
echo "  MRF simpleFoam 完了"

# ---------------------------------------------------------------------------
# Step 6b: mapFields（MRF → pimpleFoam 初期値転写）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6b] mapFields: MRF → pimpleFoam"

# pimpleFoam ケースの 0/ を 0.orig/ から復元する。
# メッシュ生成ジョブで 0/ が 0.mesh/ に置換されたため、ソルバー実行前に
# AMI パッチを含む正規の初期条件 (0.orig/) を復元する必要がある。
cd "${TRANSIENT_DIR}"
restore0Dir
echo "  pimpleFoam ケース 0/ を restore0Dir (0.orig/) で初期化"

cd "${MRF_DIR}"

# foamListTimes の出力から数値のみ抽出（バナー行・警告行を除去）
LATEST_TIME=$(foamListTimes -latestTime 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+)?$' | tail -1)
if [ -z "${LATEST_TIME}" ]; then
    echo "ERROR: MRF の出力タイムディレクトリが見つかりません"
    echo "  simpleFoam が正常終了しているか log.simpleFoam を確認してください"
    exit 1
fi
echo "  最新タイム: ${LATEST_TIME}"

# 0.backup を安全に上書き（既存でも cp -r は内部に入れてしまうため削除してから実行）
rm -rf "${TRANSIENT_DIR}/0.backup"
cp -r "${TRANSIENT_DIR}/0" "${TRANSIENT_DIR}/0.backup"

# mapFields 実行
#   第1引数 (.) = source case = MRF_DIR (cd で移動済み)
#   -case TRANSIENT_DIR = target (書き込み先)
mapFields \
    . \
    -consistent \
    -sourceTime "${LATEST_TIME}" \
    -case "${TRANSIENT_DIR}" \
    2>&1 | tee log.mapFields

# マッピング結果の確認（uniform (0 0 0) のままなら mapFields が失敗している）
echo "  0/U internalField 確認:"
grep -A2 "^internalField" "${TRANSIENT_DIR}/0/U" | head -4

echo "  mapFields 完了"

# ---------------------------------------------------------------------------
# Step 6c: pimpleFoam（非定常計算）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6c] pimpleFoam 実行"
cd "${TRANSIENT_DIR}"

# pimpleFoam が途中終了しても結果を GCS にアップロードするため
# このブロックのみ set -e を一時解除して終了コードを手動で捕捉する。
# PIMPLE_EXIT は事前に初期化して set -u エラーを防ぐ。
PIMPLE_EXIT=0
set +e
if [ "${NCORES}" -gt 1 ]; then
    decomposePar -force 2>&1 | tee log.decomposePar
    mpirun --allow-run-as-root --oversubscribe -np "${NCORES}" \
        pimpleFoam -parallel 2>&1 | tee log.pimpleFoam
    # PIPESTATUS[0] = mpirun の終了コード（tee は [1]）
    PIMPLE_EXIT=${PIPESTATUS[0]}
    reconstructPar 2>&1 | tee log.reconstructPar
    rm -rf processor[0-9]*
else
    pimpleFoam 2>&1 | tee log.pimpleFoam
    PIMPLE_EXIT=${PIPESTATUS[0]}
fi
set -e
echo "  pimpleFoam 完了 (exit: ${PIMPLE_EXIT})"

# ---------------------------------------------------------------------------
# Step 7: 結果を GCS へアップロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 7] 結果を GCS へアップロード"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GCS_DEST="gs://${GCS_BUCKET}/${GCS_RESULT_PREFIX}/LK-1_HD0.45_${TIMESTAMP}"
echo "  宛先: ${GCS_DEST}/"

# processor* ディレクトリは除外（reconstructPar 済み）
# -x オプションは Python 正規表現を使用（[0-9]+ で1桁以上の数字にマッチ）
gsutil -m cp -r \
    -x "processor[0-9]+" \
    "${TRANSIENT_DIR}/" \
    "${GCS_DEST}/"

# MRF ログも保存
gsutil -m cp \
    "${MRF_DIR}/log."* \
    "${GCS_DEST}/mrf_logs/" 2>/dev/null || true

# 最新結果パスを記録
printf '%s/\n' "${GCS_DEST}" | gsutil cp - \
    "gs://${GCS_BUCKET}/${GCS_RESULT_PREFIX}/latest.txt"

echo "  アップロード完了: ${GCS_DEST}/"

echo ""
echo "========================================"
echo "  ジョブ完了"
echo "  結果: ${GCS_DEST}/"
echo "========================================"

exit "${PIMPLE_EXIT}"
