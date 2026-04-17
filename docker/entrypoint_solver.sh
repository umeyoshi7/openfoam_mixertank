#!/bin/bash
#------------------------------------------------------------------------------
# entrypoint_solver.sh: Vertex AI Custom Job エントリポイント（ソルバー）
#
# ワークフロー:
#   1. GCS からケースファイルをダウンロード
#   2. OpenFOAM 環境読み込み
#   3. GCS から polyMesh + fvMesh をダウンロード
#      （GCS_MESH_PATH または mesh/latest.txt 参照）
#   4. polyMesh + fvMesh シンボリックリンク再作成（MRF ケース用）
#   5. decomposeParDict を NCORES に更新
#   6a. MRF foamRun（定常収束）
#   6b. Python internalField コピー（MRF → pimpleFoam 初期値転写）
#       ※ mapFields -consistent は OF11 NCC メッシュでセグフォルトするため不使用
#   6c. foamRun（非定常計算、dynamicMesh + NCC）
#   7. 結果を GCS へアップロード
#
# 環境変数:
#   GCS_BUCKET          GCS バケット名 (必須)
#   NCORES              MPI コア数 (デフォルト: 4)
#   GCS_RESULT_PREFIX   結果の GCS プレフィックス (デフォルト: results)
#   MRF_END_TIME        MRF 計算の終了イテレーション数 (デフォルト: 3000)
#   GCS_MESH_PATH       メッシュの GCS パス (省略時: mesh/latest.txt から自動取得)
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
MRF_DIR="${WORKSPACE}/LKHD045MRF"
TRANSIENT_DIR="${WORKSPACE}/LKHD045"

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
gsutil -m cp -r "gs://${GCS_BUCKET}/cases/LKHD045"     "${WORKSPACE}/"
gsutil -m cp -r "gs://${GCS_BUCKET}/cases/LKHD045MRF" "${WORKSPACE}/"
echo "  ダウンロード完了"

# ---------------------------------------------------------------------------
# Step 2: OpenFOAM 環境読み込み
# ---------------------------------------------------------------------------
echo ""
echo "[Step 2] OpenFOAM 環境読み込み"
# OpenFOAM bashrc は未設定変数の参照や非ゼロ終了を含むため、
# -e（エラー終了）と -u（未定義変数）のみ一時解除する。
# pipefail は無効化しない（-e が OFF の間は pipefail の有無は動作に影響しない）。
# BASHRC_EXIT=$? で $? を 0 にリセットしてから strict mode を再有効化する。
set +eu
# shellcheck disable=SC1091
source /opt/openfoam11/etc/bashrc
BASHRC_EXIT=$?
set -eu

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
# Step 3: GCS から polyMesh + fvMesh をダウンロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] polyMesh + fvMesh の解決とダウンロード"

if [ -z "${GCS_MESH_PATH}" ]; then
    echo "  GCS_MESH_PATH 未設定 → gs://${GCS_BUCKET}/mesh/latest.txt から取得"
    GCS_MESH_PATH=$(gsutil cat "gs://${GCS_BUCKET}/mesh/latest.txt" 2>/dev/null \
        | tr -d '[:space:]')
fi
if [ -z "${GCS_MESH_PATH}" ]; then
    echo "ERROR: メッシュパスを特定できません。"
    echo "  GCS_MESH_PATH 環境変数を設定するか、メッシュ生成ジョブを先に実行してください。"
    exit 1
fi
echo "  使用メッシュ: ${GCS_MESH_PATH}"

# constant/polyMesh/: メッシュ本体
mkdir -p "${TRANSIENT_DIR}/constant/polyMesh"
gsutil -m cp -r "${GCS_MESH_PATH}polyMesh" "${TRANSIENT_DIR}/constant/"

# constant/fvMesh/: NCC スティッチャー用データ (polyFaces)
# createNonConformalCouples が生成したもの。存在しない場合はスキップ。
if gsutil -q stat "${GCS_MESH_PATH}fvMesh/" 2>/dev/null; then
    mkdir -p "${TRANSIENT_DIR}/constant/fvMesh"
    gsutil -m cp -r "${GCS_MESH_PATH}fvMesh" "${TRANSIENT_DIR}/constant/"
else
    echo "  fvMesh が GCS に存在しません（古いメッシュジョブの可能性）、スキップ"
fi
echo "  メッシュダウンロード完了"

# ---------------------------------------------------------------------------
# Step 4: polyMesh + fvMesh シンボリックリンク再作成（MRF ケース用）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] polyMesh + fvMesh シンボリックリンク再作成"
mkdir -p "${MRF_DIR}/constant"

# GCS はシンボリックリンクを保存できないため、ダウンロード後に必ず再作成する。
# polyMesh: メッシュ本体
rm -rf "${MRF_DIR}/constant/polyMesh"
ln -sf "../../LKHD045/constant/polyMesh" "${MRF_DIR}/constant/polyMesh"
echo "  ${MRF_DIR}/constant/polyMesh -> ../../LKHD045/constant/polyMesh"

if [ ! -f "${MRF_DIR}/constant/polyMesh/faces" ]; then
    echo "ERROR: polyMesh シンボリックリンクが正しく解決されません"
    exit 1
fi

# fvMesh: NCC スティッチャー用データ（NCC パッチがあれば必要）
if [ -d "${TRANSIENT_DIR}/constant/fvMesh" ]; then
    rm -rf "${MRF_DIR}/constant/fvMesh"
    ln -sf "../../LKHD045/constant/fvMesh" "${MRF_DIR}/constant/fvMesh"
    echo "  ${MRF_DIR}/constant/fvMesh -> ../../LKHD045/constant/fvMesh"
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
# Step 6a: MRF foamRun（定常収束）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6a] MRF foamRun 実行 (endTime=${MRF_END_TIME})"
cd "${MRF_DIR}"

restore0Dir
foamDictionary -entry endTime -set "${MRF_END_TIME}" system/controlDict

decomposePar -force 2>&1 | tee log.decomposePar
mpirun --allow-run-as-root --oversubscribe -np "${NCORES}" \
    foamRun -solver incompressibleFluid -parallel 2>&1 | tee log.foamRun_MRF
reconstructPar -latestTime 2>&1 | tee log.reconstructPar_MRF
rm -rf processor[0-9]*
echo "  MRF foamRun 完了"

# ---------------------------------------------------------------------------
# Step 6b: Python internalField コピー（MRF → pimpleFoam 初期値転写）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6b] internalField コピー: MRF → pimpleFoam"

# pimpleFoam ケースの 0/ を 0.orig/ から復元（mapFields のターゲットとして必要）
cd "${TRANSIENT_DIR}"
restore0Dir
echo "  pimpleFoam ケース 0/ を restore0Dir (0.orig/) で初期化"

cd "${MRF_DIR}"

# foamListTimes から数値のみ抽出（バナー行・警告行を除去）
LATEST_TIME=$(foamListTimes -latestTime 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+)?$' | tail -1)
if [ -z "${LATEST_TIME}" ]; then
    echo "ERROR: MRF の出力タイムディレクトリが見つかりません"
    exit 1
fi
echo "  最新タイム: ${LATEST_TIME}"

# NOTE: mapFields -consistent は OF11 NCC メッシュでセグフォルトするため使用不可。
#       Python で internalField のみ MRF 解からコピーし、BC は pimpleFoam 0.orig/ を維持する。
python3 - << PYEOF
import os, re, sys

MRF_DIR   = "${MRF_DIR}"
TRAN_DIR  = "${TRANSIENT_DIR}"
MRF_TIME  = "${LATEST_TIME}"
SRC_DIR   = os.path.join(MRF_DIR, MRF_TIME)
TGT_DIR   = os.path.join(TRAN_DIR, "0")

def split_foam_field(text):
    """boundaryField ブロックの開始位置で分割する。"""
    m = re.search(r'\bboundaryField\s*\{', text)
    if not m:
        return text, None
    brace_start = m.end()
    depth = 1
    i = brace_start
    while i < len(text) and depth > 0:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1
    return text[:m.start()], text[m.start():i]

fields = ['U', 'p', 'k', 'epsilon', 'nut']
errors = 0

for field in fields:
    src = os.path.join(SRC_DIR, field)
    tgt = os.path.join(TGT_DIR, field)
    if not os.path.exists(src):
        print(f"  SKIP {field}: MRF ソースが存在しません ({src})")
        continue
    if not os.path.exists(tgt):
        print(f"  SKIP {field}: pimpleFoam ターゲットが存在しません ({tgt})")
        continue
    with open(src) as f:
        src_text = f.read()
    with open(tgt) as f:
        tgt_text = f.read()
    src_before, _ = split_foam_field(src_text)
    _, tgt_boundary = split_foam_field(tgt_text)
    if tgt_boundary is None:
        print(f"  ERROR {field}: pimpleFoam 0/ に boundaryField が見当たりません")
        errors += 1
        continue
    result = src_before + tgt_boundary + '\n\n// ************************************************************************* //\n'
    with open(tgt, 'w') as f:
        f.write(result)
    print(f"  {field}: OK ({os.path.getsize(tgt) // 1024}K)")

if errors > 0:
    sys.exit(1)
PYEOF

echo "  internalField コピー完了"

# ---------------------------------------------------------------------------
# Step 6c: foamRun（非定常計算、dynamicMesh + NCC）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6c] foamRun (transient) 実行"
cd "${TRANSIENT_DIR}"

# foamRun が途中終了しても結果を GCS にアップロードするため
# このブロックのみ set -e を一時解除して終了コードを手動で捕捉する。
TRANSIENT_EXIT=0
set +e
decomposePar -force 2>&1 | tee log.decomposePar_transient
mpirun --allow-run-as-root --oversubscribe -np "${NCORES}" \
    foamRun -solver incompressibleFluid -parallel 2>&1 | tee log.foamRun
TRANSIENT_EXIT=${PIPESTATUS[0]}
reconstructPar 2>&1 | tee log.reconstructPar_transient
rm -rf processor[0-9]*
set -e
echo "  foamRun (transient) 完了 (exit: ${TRANSIENT_EXIT})"

# ---------------------------------------------------------------------------
# Step 7: 結果を GCS へアップロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 7] 結果を GCS へアップロード"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GCS_DEST="gs://${GCS_BUCKET}/${GCS_RESULT_PREFIX}/LKHD045_${TIMESTAMP}"
echo "  宛先: ${GCS_DEST}/"

# processor* ディレクトリは除外（reconstructPar 済み）
gsutil -m cp -r \
    -x "processor[0-9]+" \
    "${TRANSIENT_DIR}/" \
    "${GCS_DEST}/"

# MRF ログも保存
gsutil -m cp \
    "${MRF_DIR}/log."* \
    "${GCS_DEST}/mrf_logs/" 2>/dev/null || true

printf '%s/\n' "${GCS_DEST}" | gsutil cp - \
    "gs://${GCS_BUCKET}/${GCS_RESULT_PREFIX}/latest.txt"

echo "  アップロード完了: ${GCS_DEST}/"

echo ""
echo "========================================"
echo "  ジョブ完了"
echo "  結果: ${GCS_DEST}/"
echo "========================================"

exit "${TRANSIENT_EXIT}"
