#!/bin/bash
#------------------------------------------------------------------------------
# test_solver_local.sh
# Vertex AI ソルバーパイプラインのローカル検証スクリプト
#
# GCS なし・シリアル実行でフルパイプラインを確認する：
#   blockMesh → surfaceFeatures → snappyHexMesh
#   → createBaffles → createNonConformalCouples → checkMesh
#   → MRF foamRun (endTime=5)
#   → Python internalField コピー
#   → transient foamRun (endTime=2e-4、初動確認のみ)
#
# 実行方法（WSL から）:
#   bash /tmp/test_solver_local.sh 2>&1 | tee /tmp/test_solver_local.log
#------------------------------------------------------------------------------
set -euo pipefail

CASE_SRC=$(ls -d /mnt/c/Users/umeyo/OneDrive/*/GitHub/openfoam_mixertank 2>/dev/null | head -1)
WORK=/tmp/of_test_solver
MRF_DIR="${WORK}/LKHD045MRF"
TRAN_DIR="${WORK}/LKHD045"

echo "========================================"
echo "  OpenFOAM 11 ローカルソルバーテスト"
echo "  ソース: ${CASE_SRC}"
echo "  作業DIR: ${WORK}"
echo "========================================"

# OpenFOAM 環境
set +eu
source /opt/openfoam11/etc/bashrc
set -eu
if [ -z "${WM_PROJECT_VERSION:-}" ]; then
    echo "ERROR: OpenFOAM 環境の読み込みに失敗"
    exit 1
fi
echo "  OpenFOAM: ${WM_PROJECT}-${WM_PROJECT_VERSION}"

. "${WM_PROJECT_DIR}/bin/tools/RunFunctions"
if ! type restore0Dir > /dev/null 2>&1; then
    restore0Dir() {
        if [ -d 0.orig ]; then rm -rf 0; cp -r 0.orig 0; fi
    }
fi

# ---------------------------------------------------------------------------
# セットアップ: 作業ディレクトリを初期化
# ---------------------------------------------------------------------------
echo ""
echo "[Setup] 作業ディレクトリ初期化: ${WORK}"
rm -rf "${WORK}"
mkdir -p "${WORK}"
cp -r "${CASE_SRC}/LKHD045"    "${TRAN_DIR}"
cp -r "${CASE_SRC}/LKHD045MRF" "${MRF_DIR}"
echo "  コピー完了"

# ---------------------------------------------------------------------------
# Step 1: blockMesh
# ---------------------------------------------------------------------------
echo ""
echo "[Step 1] blockMesh"
cd "${TRAN_DIR}"
blockMesh 2>&1 | tee log.blockMesh
echo "  blockMesh 完了"

# ---------------------------------------------------------------------------
# Step 2: surfaceFeatures (OF11)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 2] surfaceFeatures"
cd "${TRAN_DIR}"
surfaceFeatures 2>&1 | tee log.surfaceFeatures
echo "  surfaceFeatures 完了"

# ---------------------------------------------------------------------------
# Step 3: snappyHexMesh (シリアル)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] snappyHexMesh (シリアル)"
cd "${TRAN_DIR}"
# snappy は 0.mesh/ の BC を使用する
rm -rf 0
cp -r 0.mesh 0
snappyHexMesh -overwrite 2>&1 | tee log.snappyHexMesh
echo "  snappyHexMesh 完了"

# ---------------------------------------------------------------------------
# Step 4: createBaffles
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] createBaffles"
cd "${TRAN_DIR}"
createBaffles -overwrite 2>&1 | tee log.createBaffles
echo "  createBaffles 完了"

# ---------------------------------------------------------------------------
# Step 5: createNonConformalCouples
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5] createNonConformalCouples"
cd "${TRAN_DIR}"
createNonConformalCouples AMI1 AMI2 -overwrite 2>&1 | tee log.createNCC
echo "  createNonConformalCouples 完了"

# ---------------------------------------------------------------------------
# Step 6: checkMesh
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6] checkMesh"
cd "${TRAN_DIR}"
checkMesh 2>&1 | tee log.checkMesh
echo "  checkMesh 完了"

# ---------------------------------------------------------------------------
# Step 7: polyMesh/fvMesh を MRF ケースへシンボリックリンク
# ---------------------------------------------------------------------------
echo ""
echo "[Step 7] MRF ケースへ polyMesh/fvMesh シンボリックリンク"
rm -rf "${MRF_DIR}/constant/polyMesh"
ln -sf "../../LKHD045/constant/polyMesh" "${MRF_DIR}/constant/polyMesh"
echo "  polyMesh リンク: ${MRF_DIR}/constant/polyMesh"

if [ -d "${TRAN_DIR}/constant/fvMesh" ]; then
    rm -rf "${MRF_DIR}/constant/fvMesh"
    ln -sf "../../LKHD045/constant/fvMesh" "${MRF_DIR}/constant/fvMesh"
    echo "  fvMesh リンク: ${MRF_DIR}/constant/fvMesh"
else
    echo "  fvMesh なし (スキップ)"
fi

if [ ! -f "${MRF_DIR}/constant/polyMesh/faces" ]; then
    echo "ERROR: polyMesh シンボリックリンクが正しく解決されません"
    exit 1
fi
echo "  シンボリックリンク確認 OK"

# ---------------------------------------------------------------------------
# Step 8a: MRF foamRun (シリアル, endTime=5)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 8a] MRF foamRun (シリアル, endTime=5)"
cd "${MRF_DIR}"
restore0Dir
foamDictionary -entry endTime -set 5 system/controlDict
foamDictionary -entry writeInterval -set 1 system/controlDict
foamRun -solver incompressibleFluid 2>&1 | tee log.foamRun_MRF
echo "  MRF foamRun 完了"

# ---------------------------------------------------------------------------
# Step 8b: Python internalField コピー (MRF → pimpleFoam)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 8b] Python internalField コピー"
cd "${TRAN_DIR}"
restore0Dir
echo "  pimpleFoam 0/ を 0.orig/ で初期化"

cd "${MRF_DIR}"
LATEST_TIME=$(foamListTimes -latestTime 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+)?$' | tail -1)
if [ -z "${LATEST_TIME}" ]; then
    echo "ERROR: MRF の出力タイムディレクトリが見つかりません"
    exit 1
fi
echo "  MRF 最新タイム: ${LATEST_TIME}"

python3 - << PYEOF
import os, re, sys

MRF_DIR   = "${MRF_DIR}"
TRAN_DIR  = "${TRAN_DIR}"
MRF_TIME  = "${LATEST_TIME}"
SRC_DIR   = os.path.join(MRF_DIR, MRF_TIME)
TGT_DIR   = os.path.join(TRAN_DIR, "0")

def split_foam_field(text):
    m = re.search(r'\bboundaryField\s*\{', text)
    if not m:
        return text, None
    brace_start = m.end()
    depth = 1
    i = brace_start
    while i < len(text) and depth > 0:
        if text[i] == '{': depth += 1
        elif text[i] == '}': depth -= 1
        i += 1
    return text[:m.start()], text[m.start():i]

fields = ['U', 'p', 'k', 'epsilon', 'nut']
errors = 0
for field in fields:
    src = os.path.join(SRC_DIR, field)
    tgt = os.path.join(TGT_DIR, field)
    if not os.path.exists(src):
        print(f"  SKIP {field}: MRF ソースが存在しません")
        continue
    if not os.path.exists(tgt):
        print(f"  SKIP {field}: pimpleFoam ターゲットが存在しません")
        continue
    with open(src) as f: src_text = f.read()
    with open(tgt) as f: tgt_text = f.read()
    src_before, _ = split_foam_field(src_text)
    _, tgt_boundary = split_foam_field(tgt_text)
    if tgt_boundary is None:
        print(f"  ERROR {field}: pimpleFoam 0/ に boundaryField が見当たりません")
        errors += 1
        continue
    result = src_before + tgt_boundary + '\n\n// ************************************************************************* //\n'
    with open(tgt, 'w') as f: f.write(result)
    print(f"  {field}: OK ({os.path.getsize(tgt) // 1024}K)")

if errors > 0:
    sys.exit(1)
PYEOF
echo "  internalField コピー完了"

# ---------------------------------------------------------------------------
# Step 8c: transient foamRun (シリアル, endTime=2e-4)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 8c] transient foamRun (シリアル, endTime=2e-4)"
cd "${TRAN_DIR}"
# テスト用に endTime を短縮 (deltaT=1e-4 の 2 ステップ)
foamDictionary -entry endTime -set 2e-4 system/controlDict
foamDictionary -entry writeInterval -set 1e-4 system/controlDict

TRANSIENT_EXIT=0
set +e
foamRun -solver incompressibleFluid 2>&1 | tee log.foamRun_transient
TRANSIENT_EXIT=$?
set -e

if [ "${TRANSIENT_EXIT}" -eq 0 ]; then
    echo "  transient foamRun 完了 (正常終了)"
else
    echo "  transient foamRun 終了コード: ${TRANSIENT_EXIT} (エラーログを確認)"
fi

# ---------------------------------------------------------------------------
# 結果サマリ
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  テスト完了"
echo "  作業DIR: ${WORK}"
echo "  ログ一覧:"
ls "${TRAN_DIR}"/log.* 2>/dev/null
ls "${MRF_DIR}"/log.* 2>/dev/null
echo "========================================"

exit "${TRANSIENT_EXIT}"
