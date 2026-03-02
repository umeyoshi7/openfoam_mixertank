#!/bin/bash
# validate.sh: 動作検証用 (endTime=20, シリアル実行)
cd "${0%/*}" || exit 1

FOAM_ROOT="/opt/OpenFOAM/OpenFOAM-v2012"
source "${FOAM_ROOT}/etc/bashrc" 2>/dev/null

echo "=== OpenFOAM version ==="
simpleFoam --version 2>&1 | head -3 || foamVersion 2>&1 | head -3

# --- polyMesh シンボリックリンク作成 ---
if [ ! -e constant/polyMesh ]; then
    ln -s ../../LK-1_HD0.45/constant/polyMesh constant/polyMesh
    echo "[OK] constant/polyMesh symlink created"
else
    echo "[OK] constant/polyMesh already exists"
fi
ls -la constant/polyMesh

# --- 0/ をリセット ---
rm -rf 0
cp -r 0.orig 0
echo "[OK] 0/ restored from 0.orig/"

# --- system/controlDict を検証用に上書き (endTime=20) ---
cp system/controlDict system/controlDict.bak
foamDictionary -entry endTime      -set 20  system/controlDict
foamDictionary -entry writeInterval -set 10  system/controlDict
foamDictionary -entry purgeWrite   -set 0   system/controlDict
echo "[OK] controlDict: endTime=20, writeInterval=10"

# --- simpleFoam 実行 ---
echo "[RUN] simpleFoam ..."
simpleFoam > log.validate 2>&1
RC=$?

# --- controlDict を元に戻す ---
mv system/controlDict.bak system/controlDict
echo "[OK] controlDict restored"

# --- 結果確認 ---
echo ""
echo "===== Exit code: $RC ====="
echo ""
echo "--- 最後の 50 行 (log.validate) ---"
tail -50 log.validate

echo ""
echo "--- エラー・警告チェック ---"
grep -i "FATAL\|error\|abort\|warning" log.validate | head -20
