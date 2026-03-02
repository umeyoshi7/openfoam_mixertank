#!/bin/bash
source /opt/OpenFOAM/OpenFOAM-v2012/etc/bashrc

CASE="$(dirname "$0")/LK-1_HD0.45_MRF"
cd "$CASE" || { echo "ERROR: cannot cd to $CASE"; exit 1; }

echo "=== Working directory: $(pwd) ==="

# controlDict バックアップと endTime=20 設定
cp system/controlDict system/controlDict.bak
foamDictionary -entry endTime -set 20 system/controlDict
echo "--- endTime set to: $(foamDictionary -entry endTime system/controlDict) ---"

# simpleFoam 実行
echo "=== Running simpleFoam (20 iterations) ==="
simpleFoam > log.simpleFoam 2>&1
echo "Exit code: $?"

# powerLaw モデルロード確認
echo ""
echo "=== powerLaw model check ==="
grep -i "powerlaw\|viscosityModel\|transportModel" log.simpleFoam | head -10

# 残差確認
echo ""
echo "=== Residuals (last 5 Ux) ==="
grep "Ux.*Initial" log.simpleFoam | tail -5

# nu フィールド確認
echo ""
echo "=== nu field check ==="
ls 20/nu 2>/dev/null && echo "nu file exists" || echo "nu file not found (may be normal)"

# controlDict 復元
cp system/controlDict.bak system/controlDict
echo ""
echo "=== controlDict restored ==="
