# CLAUDE.md — OpenFOAM プロジェクト コンテキスト

## プロジェクト概要

攪拌槽内流れの OpenFOAM シミュレーション。
**主目的**: MRF (Multiple Reference Frame) + `simpleFoam` で定常収束解を得て、それを `pimpleFoam`（動的メッシュ + AMI）の初期値として使うことで、非定常計算の収束を大幅に高速化する。

---

## ディレクトリ構成

```
test/
├── LK-1_HD0.45/          # 非定常ケース (pimpleFoam + 動的メッシュ + AMI)
└── LK-1_HD0.45_MRF/      # 定常ケース (simpleFoam + MRF) ← 初期値生成用
```

### 命名規則

- `LK-1` : リアクター形状識別子
- `HD0.45` : 液面高さ比 H/D = 0.45
- `_MRF` サフィックス: MRF + simpleFoam 定常ケースを示す

---

## 両ケースの対応関係

| 設定項目 | LK-1_HD0.45 (pimpleFoam) | LK-1_HD0.45_MRF (simpleFoam) |
|---------|--------------------------|-------------------------------|
| ソルバー | pimpleFoam | simpleFoam |
| 時間 | 非定常 (Euler) | 定常 (steadyState) |
| 回転実装 | dynamicMesh solidBodyRotation + AMI | MRFProperties |
| impeller BC | movingWallVelocity | rotatingWallVelocity (omega=-10.47) |
| 圧力 BC | reactor_HD0.45: fixedValue 0 | 全壁: zeroGradient + pRefPoint |
| polyMesh | constant/polyMesh (実体) | constant/polyMesh → シンボリックリンク |

---

## 重要な設計判断と注意点

### 1. polyMesh はシンボリックリンクで共有
`LK-1_HD0.45_MRF/constant/polyMesh` は `../../LK-1_HD0.45/constant/polyMesh` へのシンボリックリンク。
→ Allrun 実行時に自動作成。パスは**シンボリックリンク配置場所からの相対パス**なので `../../` が必要（`../` では1段不足）。

### 2. mapFields の引数順序（要注意）
```sh
# 正しい: source=MRF, target=pimpleFoam
mapFields -consistent -sourceTime <T> -case <target> <source>
mapFields -consistent -sourceTime 3000 -case ../LK-1_HD0.45 .

# 誤り（source/target が逆）:
mapFields -consistent -sourceTime 3000 ../LK-1_HD0.45 -case .
```

### 3. mapFields は BC 型を上書きしない
`mapFields -consistent` はフィールドの**値のみコピー**し、BC の type は変更しない。
→ pimpleFoam 側の `impeller_HD0.45: movingWallVelocity` は mapFields 後も維持される。

### 4. AMI と MRF の共存
`MRFProperties` で `nonRotatingPatches (AMI1 AMI2)` を指定すること。
→ AMI パッチへの MRF ソース項の二重適用を防ぐ。

### 5. 圧力境界条件
- **simpleFoam**: 閉鎖系（inlet/outlet なし）のため全壁 `zeroGradient` + `fvSolution/SIMPLE` の `pRefPoint` で圧力参照
- **pimpleFoam**: `reactor_HD0.45: fixedValue 0`（元設定を維持）

### 6. mapToTransient.sh は `./` で実行
スクリプト内の `cd "${0%/*}"` は `./mapToTransient.sh` 形式でないと正しく動作しない。
`bash mapToTransient.sh` では失敗する。

---

## 検証済み動作環境

- OpenFOAM v2012 (linux64Gcc63DPInt32Opt)
- WSL Ubuntu-20.04 on Windows 11
- simpleFoam: シリアル実行 & 2並列 (scotch) 対応
- pimpleFoam: シリアル実行で動作確認済み

---

## 検証で確認した残差レベル

| フェーズ | U 初期残差 (1ステップ目) |
|---------|----------------------|
| ゼロ初期値から pimpleFoam 起動 | ~1.0 |
| MRF解（20 iter）→ mapFields 後 | ~2.3e-4 |
| MRF解（収束済み 3000 iter）→ mapFields 後 | さらに低い値が期待される |

---

## よく使うコマンド

```sh
# MRF 定常計算
cd LK-1_HD0.45_MRF && ./Allrun

# 収束確認
grep -E "^Time =|Ux.*Initial" log.simpleFoam | tail -20

# フィールドマッピング
cd LK-1_HD0.45_MRF && ./mapToTransient.sh

# マッピング後の確認
grep -A3 "^internalField" ../LK-1_HD0.45/0/U | head -5

# pimpleFoam 実行（既存 Allrun がない場合）
cd LK-1_HD0.45 && pimpleFoam > log.pimpleFoam 2>&1 &
```

---

## ファイル変更時の確認事項

- `MRFProperties` を変更する場合 → `omega`, `axis`, `origin` を `dynamicMeshDict` と一致させること
- `0/U` の `impeller_HD0.45` BC を変更する場合 → MRF ケースは `rotatingWallVelocity`、pimpleFoam ケースは `movingWallVelocity`（別々に管理）
- `decomposeParDict` の並列数を変更する場合 → `Allrun` の `-np` 引数も合わせて変更

---

## 他ケースへの適用時に変更すべき箇所

1. `MRFProperties`: `cellZone`, `omega`, `axis`, `origin`, `nonRotatingPatches`
2. `0/U`: 回転壁の `omega`, `axis`, `origin`
3. `system/mapFieldsDict`（pimpleFoam側）: `patchMap` のパッチ名リスト
4. `mapToTransient.sh`: `TRANSIENT_CASE` 変数
5. `Allrun`: シンボリックリンクの相対パス
6. `fvSolution/SIMPLE`: `pRefPoint`（メッシュ内の任意の点）
