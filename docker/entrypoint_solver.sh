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
#   MRF_END_TIME        MRF 計算の終了イテレーション数 (デフォルト: 5000)
#   TRANSIENT_END_TIME  transient 計算の終了時刻 [s] (省略時: controlDict の値を使用)
#   GCS_MESH_PATH       メッシュの GCS パス (省略時: mesh/latest.txt から自動取得)
#------------------------------------------------------------------------------
set -euo pipefail

GCS_BUCKET="${GCS_BUCKET:?ERROR: 環境変数 GCS_BUCKET が設定されていません}"
NCORES="${NCORES:-4}"
GCS_RESULT_PREFIX="${GCS_RESULT_PREFIX:-results}"
MRF_END_TIME="${MRF_END_TIME:-5000}"
TRANSIENT_END_TIME="${TRANSIENT_END_TIME:-}"
GCS_MESH_PATH="${GCS_MESH_PATH:-}"
WORKSPACE="/workspace"
MRF_DIR="${WORKSPACE}/LKHD045MRF"
TRANSIENT_DIR="${WORKSPACE}/LKHD045"

# エラー終了時に直近ログの末尾を表示する
on_exit() {
    local exit_code=$?
    [ "$exit_code" -eq 0 ] && return
    echo ""
    echo "========================================"
    echo "  ジョブ失敗 (exit: ${exit_code})"
    echo "========================================"
    for log in \
        "${MRF_DIR}/log.decomposePar" \
        "${MRF_DIR}/log.foamRun_MRF" \
        "${TRANSIENT_DIR}/log.decomposePar_transient" \
        "${TRANSIENT_DIR}/log.foamRun"
    do
        [ -f "$log" ] || continue
        echo "--- ${log} (末尾30行) ---"
        tail -30 "$log" || true
        echo ""
    done
}
trap on_exit EXIT

echo "========================================"
echo "  OpenFOAM Solver Job"
echo "  バケット   : gs://${GCS_BUCKET}"
echo "  コア数     : ${NCORES}"
echo "  MRF終了時刻: ${MRF_END_TIME}"
echo "  Transient終了: ${TRANSIENT_END_TIME:-controlDict の値を使用}"
echo "  作業DIR    : ${WORKSPACE}"
echo "========================================"

# ---------------------------------------------------------------------------
# Step 1: GCS からケースファイルをダウンロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 1] GCS からケースファイルをダウンロード"
gsutil -m cp -r "gs://${GCS_BUCKET}/cases/LKHD045"    "${WORKSPACE}/"
gsutil -m cp -r "gs://${GCS_BUCKET}/cases/LKHD045MRF" "${WORKSPACE}/"
echo "  ダウンロード完了"

# ---------------------------------------------------------------------------
# Step 2: OpenFOAM 環境読み込み
# ---------------------------------------------------------------------------
echo ""
echo "[Step 2] OpenFOAM 環境読み込み"
# bashrc は未設定変数参照・非ゼロ終了を含むため strict mode を一時解除する
set +eu
# shellcheck disable=SC1091
source /opt/openfoam11/etc/bashrc
set -eu

[ -n "${WM_PROJECT_VERSION:-}" ] || { echo "ERROR: OpenFOAM 環境の読み込みに失敗しました (WM_PROJECT_VERSION が未設定)"; exit 1; }
echo "  OpenFOAM: ${WM_PROJECT}-${WM_PROJECT_VERSION}"

# shellcheck disable=SC1091
. "${WM_PROJECT_DIR}/bin/tools/RunFunctions"

# RunFunctions に restore0Dir が含まれない場合のフォールバック
if ! type restore0Dir > /dev/null 2>&1; then
    restore0Dir() {
        if [ -d 0.orig ]; then
            rm -rf 0
            cp -r 0.orig 0
        fi
    }
    echo "  restore0Dir: RunFunctions に未定義のためフォールバック関数を使用"
fi

# ---------------------------------------------------------------------------
# Step 3: GCS から polyMesh + fvMesh をダウンロード
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] polyMesh + fvMesh の解決とダウンロード"

if [ -z "${GCS_MESH_PATH}" ]; then
    echo "  GCS_MESH_PATH 未設定 → gs://${GCS_BUCKET}/mesh/latest.txt から取得"
    GCS_MESH_PATH=$(gsutil cat "gs://${GCS_BUCKET}/mesh/latest.txt" 2>/dev/null \
        | tr -d '[:space:]') || true
fi

# latest.txt が存在しない場合は最新の mesh_<TIMESTAMP>/ を自動検出
if [ -z "${GCS_MESH_PATH}" ]; then
    echo "  latest.txt が見つかりません。GCS から最新メッシュディレクトリを自動検出..."
    GCS_MESH_PATH=$(gsutil ls "gs://${GCS_BUCKET}/mesh/" 2>/dev/null \
        | grep -E 'mesh_[0-9]{8}_[0-9]{6}/$' | sort | tail -1) || true
    [ -n "${GCS_MESH_PATH}" ] && echo "  自動検出: ${GCS_MESH_PATH}"
fi

if [ -z "${GCS_MESH_PATH}" ]; then
    echo "ERROR: メッシュパスを特定できません。"
    echo "  確認事項:"
    echo "    1. gs://${GCS_BUCKET}/mesh/latest.txt が存在するか"
    echo "    2. メッシュ生成ジョブが正常完了しているか"
    echo "    3. GCS_MESH_PATH 環境変数で明示的にパスを指定する"
    echo "       例: GCS_MESH_PATH=gs://${GCS_BUCKET}/mesh/mesh_YYYYMMDD_HHMMSS/"
    echo "  GCS の mesh/ ディレクトリ一覧:"
    gsutil ls "gs://${GCS_BUCKET}/mesh/" 2>&1 | head -20 || true
    exit 1
fi
GCS_MESH_PATH="${GCS_MESH_PATH%/}/"
echo "  使用メッシュ: ${GCS_MESH_PATH}"

if ! gsutil ls "${GCS_MESH_PATH}polyMesh/" >/dev/null 2>&1; then
    echo "ERROR: GCS に polyMesh が見つかりません: ${GCS_MESH_PATH}polyMesh/"
    echo "  GCS メッシュディレクトリの内容:"
    gsutil ls "${GCS_MESH_PATH}" 2>&1 | head -20 || true
    exit 1
fi

mkdir -p "${TRANSIENT_DIR}/constant/polyMesh"
# gsutil rsync を使用: cp -r はコピー先の有無で展開先が変わるが rsync は常に dst/ 配下に展開される
gsutil -m rsync -r "${GCS_MESH_PATH}polyMesh" "${TRANSIENT_DIR}/constant/polyMesh"

if [ ! -f "${TRANSIENT_DIR}/constant/polyMesh/faces" ] && \
   [ ! -f "${TRANSIENT_DIR}/constant/polyMesh/faces.gz" ]; then
    echo "ERROR: polyMesh ダウンロード後に faces/faces.gz が見つかりません"
    find "${TRANSIENT_DIR}/constant/polyMesh" -maxdepth 2 2>/dev/null | sort || true
    exit 1
fi
echo "  polyMesh ダウンロード OK"

if gsutil ls "${GCS_MESH_PATH}fvMesh/" >/dev/null 2>&1; then
    mkdir -p "${TRANSIENT_DIR}/constant/fvMesh"
    gsutil -m rsync -r "${GCS_MESH_PATH}fvMesh" "${TRANSIENT_DIR}/constant/fvMesh"
    echo "  fvMesh ダウンロード OK"
else
    echo "  fvMesh が GCS に存在しません（NCC なしのメッシュまたは古いジョブ）、スキップ"
fi

# ---------------------------------------------------------------------------
# Step 4: polyMesh + fvMesh シンボリックリンク再作成（MRF ケース用）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] polyMesh + fvMesh シンボリックリンク再作成"
mkdir -p "${MRF_DIR}/constant"

# GCS はシンボリックリンクを保存できないため、ダウンロード後に必ず再作成する
rm -rf "${MRF_DIR}/constant/polyMesh"
ln -sf "../../LKHD045/constant/polyMesh" "${MRF_DIR}/constant/polyMesh"

if [ ! -f "${MRF_DIR}/constant/polyMesh/faces" ] && \
   [ ! -f "${MRF_DIR}/constant/polyMesh/faces.gz" ]; then
    echo "ERROR: polyMesh シンボリックリンクが正しく解決されません"
    find "${TRANSIENT_DIR}/constant/polyMesh" -maxdepth 1 2>/dev/null | sort | head -20 || true
    exit 1
fi

if [ -d "${TRANSIENT_DIR}/constant/fvMesh" ]; then
    rm -rf "${MRF_DIR}/constant/fvMesh"
    ln -sf "../../LKHD045/constant/fvMesh" "${MRF_DIR}/constant/fvMesh"
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
# Step 6a-check: MRF収束品質チェック（不良初期値が transient を破壊するのを防ぐ）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6a-check] MRF収束品質チェック"
python3 - << PYEOF
import os, sys

log_path = "${MRF_DIR}/log.foamRun_MRF"
if not os.path.exists(log_path):
    print("  WARNING: log.foamRun_MRF が見つかりません。チェックをスキップします。")
    sys.exit(0)

with open(log_path) as f:
    lines = f.readlines()

cumulative    = None
bounding_eps  = 0
last_p_res    = None
epsilon_max   = None

for line in lines:
    if 'cumulative' in line:
        try:
            cumulative = float(line.strip().split()[-1])
        except (ValueError, IndexError):
            pass
    if 'bounding epsilon' in line:
        bounding_eps += 1
        if 'max:' in line:
            try:
                epsilon_max = float(line.split('max:')[1].split()[0])
            except (ValueError, IndexError):
                pass
    if 'Solving for p' in line and 'Initial residual' in line:
        try:
            last_p_res = float(line.split('Initial residual =')[1].split(',')[0])
        except (ValueError, IndexError):
            pass

print(f"  累積連続性誤差   : {cumulative}")
print(f"  epsilon bounding : {bounding_eps} 回")
print(f"  MRF epsilon 最大値: {epsilon_max}")
print(f"  最終 p 初期残差  : {last_p_res}")

if epsilon_max is not None and epsilon_max > 200:
    print(f"  [WARN] epsilon max = {epsilon_max:.1f} > 200 : Step 6b で 100 にクリップ転写されます")
    print(f"         クリップなし時の NCC スパイク推定: {epsilon_max * 2.7:.0f} → クリップ後: ~{100 * 2.7:.0f}")

failures = []
if cumulative is not None and abs(cumulative) > 1.0:
    failures.append(
        f"累積連続性誤差 {cumulative:.4f} > 1.0 "
        f"→ 圧力場が収束していないため transient で SIGFPE が発生します"
    )
if last_p_res is not None and last_p_res > 2e-3:
    failures.append(
        f"最終 p 初期残差 {last_p_res:.2e} > 2e-3 "
        f"→ 圧力場が未収束のまま転写されます"
    )

if failures:
    print("")
    print("ERROR: MRF 収束品質が不十分なため transient 計算を中断します。")
    for msg in failures:
        print(f"  - {msg}")
    print("")
    print("対策:")
    print("  1. MRF_END_TIME を増やして再実行してください (現在: ${MRF_END_TIME})")
    print("     例: MRF_END_TIME=10000")
    print("  2. LKHD045MRF/system/fvSolution の limitFields が epsilon >= 1e-6 になっているか確認してください")
    if bounding_eps > 0:
        print(f"  (補足: epsilon bounding {bounding_eps} 回発生 → 乱流場が不安定)")
    sys.exit(1)

if bounding_eps > 0:
    print(f"  [WARN] epsilon bounding が {bounding_eps} 回発生しています")
print("  [OK] MRF 収束品質は正常範囲です")
PYEOF

# ---------------------------------------------------------------------------
# Step 6b: Python internalField コピー（MRF → pimpleFoam 初期値転写）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6b] internalField コピー: MRF → pimpleFoam"

cd "${TRANSIENT_DIR}"
restore0Dir
echo "  pimpleFoam ケース 0/ を restore0Dir (0.orig/) で初期化"

cd "${MRF_DIR}"

LATEST_TIME=$(foamListTimes -latestTime 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+)?$' | tail -1)
[ -n "${LATEST_TIME}" ] || { echo "ERROR: MRF の出力タイムディレクトリが見つかりません"; exit 1; }
echo "  最新タイム: ${LATEST_TIME}"

# NOTE: mapFields -consistent は OF11 NCC メッシュでセグフォルトするため使用不可。
#       Python で internalField のみ MRF 解からコピーし、BC は pimpleFoam 0.orig/ を維持する。
#       epsilon は転写前に上限クリップ：MRF max ~330 が dynamicMesh NCC 初期化で
#       ~2.7 倍に跳ね上がり圧力ソルバーを発散させる（SIGFPE の直接原因）。
python3 - << PYEOF
import os, re, sys

MRF_DIR   = "${MRF_DIR}"
TRAN_DIR  = "${TRANSIENT_DIR}"
MRF_TIME  = "${LATEST_TIME}"
SRC_DIR   = os.path.join(MRF_DIR, MRF_TIME)
TGT_DIR   = os.path.join(TRAN_DIR, "0")

# MRF epsilon max (~330) が NCC 初期化時に ~2.7 倍スパイクする対策として
# 転写前に 100 でクリップする。これにより最悪でも ~270 に抑えられ GAMG が安定する。
EPSILON_CLIP_MAX = 100.0

def clip_nonuniform_scalar(text, field_name, max_val, min_val=1e-10):
    """internalField nonuniform List<scalar> の値を [min_val, max_val] でクリップする。"""
    pattern = r'(internalField\s+nonuniform\s+List<scalar>\s*\n?\s*\d+\s*\n?\s*\()([^)]+)(\))'
    matched = [False]
    def replacer(m):
        matched[0] = True
        raw = m.group(2)
        try:
            floats = [float(v) for v in raw.split()]
        except ValueError:
            print(f"    {field_name}: 値のパースに失敗、クリップをスキップ")
            return m.group(0)
        if not floats:
            return m.group(0)
        orig_max = max(floats)
        orig_min = min(floats)
        n_clipped = sum(1 for v in floats if v > max_val)
        clipped = [min(max(v, min_val), max_val) for v in floats]
        print(f"    {field_name} clip: [{orig_min:.3e}, {orig_max:.3e}] → max={max(clipped):.3e} ({n_clipped} セルをクリップ)")
        new_raw = '\n'.join(f'{v:.10e}' for v in clipped)
        return m.group(1) + '\n' + new_raw + '\n' + m.group(3)
    result = re.sub(pattern, replacer, text, flags=re.DOTALL)
    if not matched[0]:
        print(f"    {field_name}: nonuniform フィールドなし（uniform または空）、クリップ不要")
    return result

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

# nut は転写しない：
#   - 0.orig/nut は uniform 0 であり foamRun 起動時に kEpsilon が自動再計算する
#   - MRF の nut は epsilon_max=330 由来で異常に高く、転写すると
#     dynamicMesh 第1ステップの momentumPredictor で SIGFPE が発生する
fields = ['U', 'p', 'k', 'epsilon']
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

    # epsilon のみ転写前にクリップ
    # MRF の高 epsilon 値が dynamicMesh NCC 初期化で約 2.7 倍に跳ね上がり
    # GAMG 圧力ソルバーを発散させるため、上限を設けて初期スパイクを抑制する
    if field == 'epsilon':
        src_text = clip_nonuniform_scalar(src_text, field, EPSILON_CLIP_MAX)

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
# Step 6b-post: nut を 0.orig/nut でリセット（MRF転写値の混入防止）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6b-post] nut リセット (0.orig/nut → 0/nut)"
cp "${TRANSIENT_DIR}/0.orig/nut" "${TRANSIENT_DIR}/0/nut"
echo "  nut リセット完了 (internalField uniform 0)"

# ---------------------------------------------------------------------------
# Step 6c: foamRun（非定常計算、dynamicMesh + NCC）
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6c] foamRun (transient) 実行"
cd "${TRANSIENT_DIR}"

if [ -n "${TRANSIENT_END_TIME}" ]; then
    foamDictionary -entry endTime -set "${TRANSIENT_END_TIME}" system/controlDict
    echo "  transient endTime を ${TRANSIENT_END_TIME} s に設定"
fi

# 発散しても結果を GCS に保存するため、このブロックのみ set -e を解除
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

gsutil -m rsync -r \
    -x "processor[0-9]+" \
    "${TRANSIENT_DIR}" \
    "${GCS_DEST}"

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
