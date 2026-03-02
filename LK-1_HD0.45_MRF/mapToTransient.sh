#!/bin/sh
# mapToTransient.sh
# MRF収束解を pimpleFoam ケース (LK-1_HD0.45) の初期値としてマッピングする
# 実行場所: LK-1_HD0.45_MRF/ ディレクトリ内

cd "${0%/*}" || exit 1   # run from this directory

TRANSIENT_CASE="../LK-1_HD0.45"

# --- 最新タイムステップを取得 ---
LATEST_TIME=$(foamListTimes -latestTime 2>/dev/null | tail -1)

if [ -z "$LATEST_TIME" ]; then
    echo "Error: No time directories found in $(pwd). Run simpleFoam first."
    exit 1
fi

echo "Latest MRF time: $LATEST_TIME"

# --- pimpleFoam ケースの 0/ をバックアップ ---
if [ -d "${TRANSIENT_CASE}/0" ]; then
    BACKUP_DIR="${TRANSIENT_CASE}/0.backup"
    if [ -d "$BACKUP_DIR" ]; then
        echo "Backup directory $BACKUP_DIR already exists, overwriting..."
        rm -rf "$BACKUP_DIR"
    fi
    cp -r "${TRANSIENT_CASE}/0" "$BACKUP_DIR"
    echo "Backed up ${TRANSIENT_CASE}/0 to $BACKUP_DIR"
fi

# --- mapFields: 同一メッシュなので -consistent オプションで直接コピー ---
# 構文: mapFields [OPTIONS] <sourceCase>
#   source = .  (LK-1_HD0.45_MRF, 本スクリプトの実行ディレクトリ)
#   target = -case $TRANSIENT_CASE  (LK-1_HD0.45)
echo "Mapping fields from time $LATEST_TIME to ${TRANSIENT_CASE}/0 ..."
mapFields \
    -consistent \
    -sourceTime "$LATEST_TIME" \
    -case "$TRANSIENT_CASE" \
    .

echo "Done. Check ${TRANSIENT_CASE}/0/U to verify non-zero internalField."

#------------------------------------------------------------------------------
