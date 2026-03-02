# MRF + simpleFoam → pimpleFoam 初期値生成ケース

## 概要

`LK-1_HD0.45_MRF` は、動的メッシュ（solidBody rotation + AMI）を用いた非定常計算
（`LK-1_HD0.45` / `pimpleFoam`）の**初期値を効率よく生成する**ための定常ケースです。

MRF (Multiple Reference Frame) + `simpleFoam` で回転流の擬似定常解を得て、
`mapFields` で `pimpleFoam` ケースの `0/` ディレクトリに転写します。

### なぜこの手順が有効か

| 起動方法 | pimpleFoam 1 ステップ目の U 初期残差 |
|---------|--------------------------------------|
| ゼロ初期値 | ~1.0（最大値） |
| MRF 収束解から起動 | ~1e-4 以下（検証済み） |

初期残差が低いほど非定常計算の立ち上がりが安定・高速になります。

---

## ディレクトリ構成

```
test/
├── LK-1_HD0.45/                    # 非定常ケース（pimpleFoam）
│   ├── 0/                          # ← mapToTransient.sh がここに書き込む
│   ├── 0.orig/                     # 元の均一初期値（バックアップ用）
│   ├── constant/
│   │   ├── polyMesh/               # メッシュ実体（LK-1_HD0.45_MRF と共有）
│   │   └── dynamicMeshDict         # solidBodyRotation + AMI 設定
│   └── system/
│       └── mapFieldsDict           # mapFields 用パッチ対応表
│
└── LK-1_HD0.45_MRF/               # 定常ケース（simpleFoam + MRF）← 本ケース
    ├── 0/                          # 初期値（0.orig からリセット）
    ├── 0.orig/                     # 初期値バックアップ（Allrun でリセット元）
    ├── constant/
    │   ├── polyMesh -> ../../LK-1_HD0.45/constant/polyMesh  (シンボリックリンク)
    │   ├── MRFProperties           # MRF ゾーン定義
    │   ├── transportProperties
    │   ├── turbulenceProperties
    │   └── g
    ├── system/
    │   ├── controlDict             # simpleFoam, endTime=3000
    │   ├── fvSchemes               # ddtSchemes: steadyState
    │   ├── fvSolution              # SIMPLE + 緩和係数
    │   └── decomposeParDict        # 2並列 scotch
    ├── Allrun                      # 定常計算実行スクリプト
    ├── Allclean                    # クリーンアップスクリプト
    └── mapToTransient.sh           # フィールドマッピングスクリプト
```

---

## 実行手順

### Step 1: MRF 定常計算

```sh
cd LK-1_HD0.45_MRF
./Allrun
```

内部処理:
1. `constant/polyMesh` のシンボリックリンクを作成（未作成の場合のみ）
2. `0/` を `0.orig/` からリセット（`restore0Dir`）
3. `decomposePar` で 2 並列分割
4. `simpleFoam -parallel` で定常計算
5. `reconstructPar -latestTime` で最終タイムを再合成

**収束の目安**: 全残差（U, p, k, epsilon）が `1e-4` 以下

```sh
# 収束状況の確認
grep -E "^Time =|Solving for Ux.*Initial" log.simpleFoam | tail -30

# または postProcessing の CSV を確認
cat postProcessing/residuals/0/solverInfo.dat | tail -5
```

### Step 2: 収束確認

```sh
tail -50 log.simpleFoam
```

`residualControl` の閾値（`1e-4`）に達すると「SIMPLE solution converged」と表示されて
自動停止します。`endTime=3000` まで達した場合は残差トレンドを目視確認してください。

### Step 3: フィールドマッピング

**必ず `LK-1_HD0.45_MRF/` 内から `./` 形式で実行**:

```sh
cd LK-1_HD0.45_MRF
./mapToTransient.sh
```

処理内容:
1. 最新タイムステップを自動検出（`foamListTimes -latestTime`）
2. `LK-1_HD0.45/0/` を `LK-1_HD0.45/0.backup/` にバックアップ
3. `mapFields -consistent` でフィールドを転写

### Step 4: マッピング結果の確認

```sh
# U の internalField が非ゼロであることを確認
grep -A4 "^internalField" ../LK-1_HD0.45/0/U | head -6

# BC 型が pimpleFoam 用のまま保持されていることを確認
grep -A2 "impeller_HD0.45" ../LK-1_HD0.45/0/U
# → type movingWallVelocity であること（rotatingWallVelocity になっていないこと）
```

### Step 5: pimpleFoam 実行

```sh
cd LK-1_HD0.45
pimpleFoam > log.pimpleFoam 2>&1 &
tail -f log.pimpleFoam
```

---

## ケース設定の詳細

### MRFProperties（`constant/MRFProperties`）

```cpp
MRF1
{
    cellZone            rotating;    // 回転ゾーン名
    active              yes;
    nonRotatingPatches  (AMI1 AMI2); // AMI への二重適用を防ぐ（必須）
    origin              (0 0 0);
    axis                (0 1 0);
    omega               -10.47;      // rad/s（マイナス = 右ねじ反対向き）
}
```

`omega` の符号は `dynamicMeshDict` の `omega` と一致させること。

### 境界条件の変換（pimpleFoam → simpleFoam）

| パッチ | pimpleFoam (U) | simpleFoam (U) |
|--------|----------------|----------------|
| impeller_HD0.45 | `movingWallVelocity` | `rotatingWallVelocity` |
| shaft_HD0.45 | `rotatingWallVelocity` | `rotatingWallVelocity`（同一） |
| reactor_HD0.45 | `fixedValue (0 0 0)` | `fixedValue (0 0 0)`（同一） |
| baffle_HD0.45 | `fixedValue (0 0 0)` | `fixedValue (0 0 0)`（同一） |

| パッチ | pimpleFoam (p) | simpleFoam (p) |
|--------|----------------|----------------|
| reactor_HD0.45 | `fixedValue 0` | `zeroGradient` |
| その他壁面 | `zeroGradient` | `zeroGradient`（同一） |

simpleFoam では圧力参照を `fvSolution/SIMPLE/pRefPoint` で与えるため、
全壁を `zeroGradient` に統一します。

### fvSolution（`system/fvSolution`）

```cpp
SIMPLE
{
    nNonOrthogonalCorrectors 3;
    pRefPoint   (0 0.06 0.15);  // メッシュ内の任意の点（インターナル）
    pRefValue   0;
    residualControl { p 1e-4; U 1e-4; "(k|epsilon)" 1e-4; }
}
relaxationFactors
{
    fields    { p 0.3; }
    equations { U 0.7; k 0.5; epsilon 0.5; }
}
```

`pRefPoint` は必ずメッシュ内部の点（インターナルセル内）を指定すること。
境界面上の点を指定するとエラーになります。

---

## 流体モデルの設定

流体物性は **両ケース共通**のファイルで設定します:

- `LK-1_HD0.45_MRF/constant/transportProperties`
- `LK-1_HD0.45/constant/transportProperties`

> 両ファイルを**必ず同じ内容**に保つこと。片方だけ変更すると
> MRF 解と pimpleFoam 解で異なる物性が使われる。

---

### ニュートン流体（水など）

```cpp
transportModel  Newtonian;

nu              [0 2 -1 0 0 0 0] 1e-06;   // 動粘度 [m²/s]
```

| パラメータ | 値 | 備考 |
|-----------|-----|------|
| `nu` | `1e-06 m²/s` | 水（20°C）の動粘度 |

---

### 非ニュートン流体（疑塑性・powerLaw）

```cpp
transportModel  powerLaw;

powerLawCoeffs
{
    k       [0 2 -1 0 0 0 0] 1.686e-06;   // = K/ρ  [m²/s^n]
    n       [0 0  0 0 0 0 0] 0.567;        // 流動指数（< 1 = 疑塑性）
    nuMin   [0 2 -1 0 0 0 0] 1e-09;        // 高せん断域の下限（発散防止）
    nuMax   [0 2 -1 0 0 0 0] 1e-04;        // 低せん断域の上限（発散防止）
}
```

| パラメータ | 値 | 導出元 |
|-----------|-----|--------|
| `k` | `1.686e-06 m²/s^n` | K/ρ = 1.352e-2 / 8020 |
| `n` | `0.567` | 流動指数（shear-thinning） |
| `nuMin` | `1e-09 m²/s` | γ̇ ≈ 10000 s⁻¹ 相当（インペラ近傍） |
| `nuMax` | `1e-04 m²/s` | γ̇ ≈ 0.01 s⁻¹ 相当（死水域） |

#### パラメータ導出（スラリー実験データから）

実験条件:
- 装置: ATAGO 回転型粘度計（円柱スピンドル、R = 0.0125 m）
- 取得式: `μ [mPa·s] = 1.5 × u^(−0.433)`（u = 先端速度 m/s）
- スラリー密度: ρ = 8020 kg/m³

先端速度 u → せん断速度 γ̇ の変換（無限媒体 Couette 近似）:

```
γ̇ = 2ω = 2 × (u/R) = (2/0.0125) × u = 160 u   [s⁻¹]
```

Power-Law パラメータへの変換:

```
μ [Pa·s] = 1.5e-3 × u^(-0.433)
         = 1.5e-3 × (γ̇/160)^(-0.433)
         = 1.5e-3 × 160^(0.433) × γ̇^(-0.433)
         ≈ 1.352e-2 × γ̇^(-0.433)

Power-law 標準形: μ = K × γ̇^(n-1)
  → K = 1.352e-2 Pa·s^n,  n = 0.567
  → k = K/ρ = 1.352e-2 / 8020 = 1.686e-6 m²/s^n
```

検証:

| u [m/s] | γ̇ [s⁻¹] | μ 元式 [mPa·s] | μ 変換後 [mPa·s] |
|---------|----------|---------------|----------------|
| 0.01    | 1.6      | 5.5           | 5.5 ✓          |
| 0.10    | 16       | 4.1           | 4.1 ✓          |
| 1.00    | 160      | 1.5           | 1.5 ✓          |

---

### 切り替え手順

#### ニュートン → powerLaw

```sh
# 両ファイルを編集
vi LK-1_HD0.45_MRF/constant/transportProperties
vi LK-1_HD0.45/constant/transportProperties
```

`Newtonian` ブロックを削除し、`powerLaw` ブロックに置き換える（上記「非ニュートン流体」参照）。

#### powerLaw → ニュートン

`powerLawCoeffs` ブロックを削除し、`Newtonian` の 2 行に戻す（上記「ニュートン流体」参照）。

#### 変更後の動作確認

```sh
cd LK-1_HD0.45_MRF
cp system/controlDict system/controlDict.bak
foamDictionary -entry endTime -set 20 system/controlDict
simpleFoam > log.simpleFoam 2>&1

# モデルがロードされたか確認
grep -i "transportModel\|powerlaw\|newtonian" log.simpleFoam | head -3
# → "Selecting incompressible transport model powerLaw"  （または Newtonian）

# 残差確認
grep "Ux.*Initial" log.simpleFoam | tail -5

# controlDict を元に戻す
cp system/controlDict.bak system/controlDict
```

---

## 注意事項

### mapFields の引数順序

```sh
# 構文: mapFields [OPTIONS] <sourceCase>
# -case が target, 最後の引数が source

# 正しい（MRF → pimpleFoam）
mapFields -consistent -sourceTime 3000 -case ../LK-1_HD0.45 .

# 誤り（pimpleFoam → MRF、逆向き）
mapFields -consistent -sourceTime 3000 ../LK-1_HD0.45 -case .
```

### mapFields は BC 型を保持する

`mapFields -consistent` は**値のみコピー**し、BC の `type` は書き換えない。
→ `impeller_HD0.45: movingWallVelocity` はマッピング後も維持される（設計通りの動作）。

### シンボリックリンクのパス

`constant/polyMesh` のシンボリックリンクは「リンク自体の位置からの相対パス」で解決される。

```
constant/polyMesh → ../../LK-1_HD0.45/constant/polyMesh
                    ^^
                    constant/ から2段上 = test/ ディレクトリ
```

`../`（1段）では `LK-1_HD0.45_MRF/LK-1_HD0.45/...` と解決されるため**エラー**になる。

### mapToTransient.sh の実行形式

```sh
# 正しい: ${0%/*} がスクリプトのディレクトリに展開される
./mapToTransient.sh

# 誤り: ${0%/*} が "mapToTransient.sh" になり cd が失敗する
bash mapToTransient.sh
```

### Windows (WSL) 環境での注意

- `pimpleFoam` は動的メッシュ + AMI の AMI 再構築を毎ステップ行うため、
  大規模メッシュ（~250万セル）のシリアル計算は非常に低速（1ステップあたり数分）。
  実計算では並列（`decomposePar` + `mpirun`）を使用すること。
- Windows の NTFS ファイルシステム上での OpenFOAM の I/O は WSL ネイティブより低速。
  可能であれば WSL のホームディレクトリ（`~/OpenFOAM/...`）でケースを実行することを推奨。

---

## Allclean の動作

```sh
./Allclean
```

- `cleanCase`（OpenFOAM 標準）: タイムディレクトリ、processor*、postProcessing を削除
- `constant/polyMesh` のシンボリックリンクは**削除しない**（再作成不要）
- ログファイル（`log.*`）を削除

再計算する場合は `Allclean` → `Allrun` を実行すればよい。

---

## 他のケースへの適用（汎用手順）

### 前提条件

- pimpleFoam ケースが動的メッシュ（solidBodyRotation）+ AMI で回転流を計算している
- 同一メッシュを MRF ケースと共有できる（`-consistent` マッピングのため）
- k-epsilon（または k-omega SST 等）の 2 方程式乱流モデルを使用

### 新規 MRF ケース作成の手順

1. **本ケースをコピー**:
   ```sh
   cp -r LK-1_HD0.45_MRF NewCase_MRF
   ```

2. **変更が必要なファイル**:

   | ファイル | 変更箇所 |
   |---------|---------|
   | `constant/MRFProperties` | `cellZone`, `omega`, `axis`, `origin`, `nonRotatingPatches` |
   | `0/U` | 回転壁の `omega`, `axis`, `origin` |
   | `fvSolution` | `SIMPLE/pRefPoint`（メッシュ内の点） |
   | `mapToTransient.sh` | `TRANSIENT_CASE` 変数（相対パス） |
   | `Allrun` | シンボリックリンクのパス、並列数 `-np` |
   | `system/mapFieldsDict`（pimpleFoam側） | `patchMap` のパッチ名 |

3. **pimpleFoam ケース側で変更が必要なファイル**:
   - `system/mapFieldsDict`: `patchMap` に全パッチを列挙

4. **omega の符号確認**:
   `dynamicMeshDict` の `omega` と `MRFProperties` の `omega` を一致させる。

### AMI なしのケース（単純回転のみ）への適用

`nonRotatingPatches` を空リストにする:
```cpp
nonRotatingPatches ();
```

`0/U` の AMI パッチ設定も不要になる（削除または `cyclicAMI` 以外のBC に変更）。

### k-omega SST への変更

`0/` の `nut` に加えて `omega` フィールドを追加し、各壁面に `omegaWallFunction` を設定する。
`turbulenceProperties` で `RASModel kOmegaSST` に変更する。

---

## トラブルシューティング

### `Cannot find file "points"` エラー

**原因**: `constant/polyMesh` のシンボリックリンクが壊れている。

```sh
ls -la constant/polyMesh      # → ターゲットのパスを確認
readlink -f constant/polyMesh # → 実際に解決されるパスを確認
ls constant/polyMesh/points   # → このファイルが見えればOK
```

修正:
```sh
rm constant/polyMesh
ln -s ../../LK-1_HD0.45/constant/polyMesh constant/polyMesh
```

### simpleFoam が発散する

1. 緩和係数を下げる: `p: 0.3 → 0.2`, `U: 0.7 → 0.5`
2. `nNonOrthogonalCorrectors` を増やす: `3 → 5`
3. 初期の `epsilon` bounding メッセージは正常（数ステップで消える）

### mapFields 後に 0/U が uniform (0 0 0) のまま

**原因**: `mapFields` の source/target が逆になっている。
`mapToTransient.sh` 内のコマンドの引数順序を確認すること（上記「注意事項」参照）。

### pimpleFoam で AMI 重みが 1 からずれる警告

`AMI: Patch target sum(weights) min:0.99 max:1.01` 程度は正常範囲。
`min < 0.9` になる場合は AMI メッシュの品質を確認すること。
