# OpenFOAM 11 攪拌槽シミュレーション — Vertex AI Custom Job 実行ガイド

## 概要

OpenFOAM 11 (Foundation) を使った攪拌槽内流れシミュレーションを GCP の Vertex AI Custom Job で実行するためのガイドです。

**ワークフロー概要**:
1. **メッシュ生成ジョブ**: `blockMesh` → `snappyHexMesh` (並列) → `createBaffles` → `createNonConformalCouples` → GCS アップロード
2. **ソルバージョブ**: MRF 定常計算 → Python フィールドコピー → 非定常計算 → GCS アップロード

**主要技術**:
- OpenFOAM 11 では `simpleFoam`/`pimpleFoam` の代わりに `foamRun -solver incompressibleFluid` を使用
- 回転界面は cyclicAMI の代わりに nonConformalCyclic (NCC) + `createNonConformalCouples` で実装
- MRF 定常解のフィールドコピーは `mapFields -consistent`（NCC メッシュでセグフォルトする）の代わりに Python で `internalField` を直接コピー
- Docker コンテナを Artifact Registry に push し、Vertex AI Custom Job で実行
- 計算結果は Cloud Storage (GCS) に自動保存

---

## ケース命名規則

| 識別子 | 意味 |
|--------|------|
| `LKHD045` | リアクター形状、液面高さ比 H/D = 0.45 |
| `LKHD045MRF` | MRF 定常計算ケース（初期値生成用） |

---

## 両ケースの対応関係

| 設定項目 | LKHD045（非定常） | LKHD045MRF（MRF 定常） |
|---------|-----------------|----------------------|
| ソルバーコマンド | `foamRun -solver incompressibleFluid` | `foamRun -solver incompressibleFluid` |
| 時間離散化 | 非定常 (Euler) | 定常 (steadyState) |
| 回転実装 | dynamicMesh solidBodyRotation + NCC | MRFProperties |
| impeller/shaft BC (U) | `movingWallVelocity` | `rotatingWallVelocity` (omega=-10.47) |
| reactor/baffle BC (U) | `noSlip` | `noSlip` |
| AMI1/AMI2 BC (U) | `movingWallSlipVelocity` | `zeroGradient` (MRF nonRotatingPatches) |
| 圧力参照 | `pRefPoint` (PIMPLE ブロック) | `pRefPoint` (SIMPLE ブロック) |
| polyMesh | `constant/polyMesh/`（実体） | `constant/polyMesh` → シンボリックリンク |
| NCC パッチ | `nonConformalCyclic_on_AMI1/2`、`nonConformalError_on_AMI1/2`（0 faces） | 同左（共有メッシュ） |

---

## ワークフロー全体図

```
[ローカル / Cloud Workstations]
        |
        | docker build & push （メッシュ用 + ソルバー用）
        v
[Artifact Registry]  ←── Docker イメージ × 2
        |
        | ① Vertex AI Custom Job（メッシュ生成）
        v
[Vertex AI Worker: メッシュ生成コンテナ]
  1. GCS から cases/LKHD045 をダウンロード
  2. blockMesh
  3. surfaceFeatureExtract
  4. 0/ を 0.mesh/（最小 BC セット）で置換 → decomposePar → snappyHexMesh（並列）→ reconstructPar
  5. createBaffles → createNonConformalCouples（AMI1/AMI2 → NCC 変換）
  6. checkMesh
  7. constant/polyMesh/ + constant/fvMesh/ を GCS へアップロード
        |
        v
[GCS: mesh/mesh_<TIMESTAMP>/polyMesh/ + fvMesh/]
        |
        | ② Vertex AI Custom Job（ソルバー）
        v
[Vertex AI Worker: ソルバーコンテナ]
  1. GCS から cases/LKHD045 + cases/LKHD045MRF をダウンロード
  2. GCS から polyMesh + fvMesh をダウンロード → LKHD045MRF に symlink 作成
  3. foamRun -solver incompressibleFluid（MRF 定常、並列）
  4. Python: MRF の internalField を LKHD045/0/ にコピー（BC は 0.orig/ を維持）
  5. foamRun -solver incompressibleFluid（非定常 dynamicMesh + NCC、並列）
  6. 結果を GCS へアップロード
        |
        v
[GCS: results/LKHD045_<TIMESTAMP>/]
```

---

## ディレクトリ構成

```
openfoam_mixertank/
├── README.md
├── .gitignore
├── .env.example                  環境変数テンプレート（.env にコピーして使用）
│
├── vertex_ai/
│   ├── job_mesh.yaml             メッシュ生成ジョブ設定
│   └── job_solver.yaml           ソルバージョブ設定
│
├── docker/
│   ├── Dockerfile.mesh
│   ├── Dockerfile.solver
│   ├── entrypoint_mesh.sh        メッシュ生成ワークフロー（10 ステップ）
│   └── entrypoint_solver.sh      ソルバーワークフロー（7 ステップ）
│
├── LKHD045/                      非定常ケース（dynamicMesh + NCC）
│   ├── 0.orig/                   pimpleFoam 初期条件（restore0Dir のコピー元）
│   ├── 0.mesh/                   snappyHexMesh 用最小 BC（AMI なし、decomposePar 前に使用）
│   ├── constant/
│   │   ├── polyMesh/             ※ .gitignore 除外（メッシュジョブが生成）
│   │   ├── fvMesh/               ※ .gitignore 除外（createNonConformalCouples が生成）
│   │   ├── extendedFeatureEdgeMesh/  ※ .gitignore 除外（surfaceFeatureExtract が生成）
│   │   ├── triSurface/           STL ファイル（メッシュ生成に使用）
│   │   └── dynamicMeshDict       solidBody 回転設定
│   └── system/
│       ├── blockMeshDict
│       ├── controlDict
│       ├── createBafflesDict
│       ├── decomposeParDict
│       ├── fvSchemes
│       ├── fvSolution
│       ├── snappyHexMeshDict
│       └── surfaceFeatureExtractDict
│
└── LKHD045MRF/                   MRF 定常ケース（初期値生成用）
    ├── 0.orig/                   MRF 初期条件（restore0Dir のコピー元）
    ├── constant/
    │   ├── polyMesh              ※ ランタイム symlink → ../../LKHD045/constant/polyMesh
    │   └── MRFProperties
    └── system/
```

> **0/ ディレクトリについて**: ランタイム作業ディレクトリのため git 管理対象外。
> ジョブ開始時に `restore0Dir`（`0.orig/` → `0/` コピー）で生成される。

---

## GCS ファイル構成

```
gs://<BUCKET>/
├── cases/                              ← ユーザーがアップロードするケースファイル
│   ├── LKHD045/
│   │   ├── 0.orig/
│   │   ├── 0.mesh/
│   │   ├── constant/
│   │   │   ├── dynamicMeshDict
│   │   │   ├── g, physicalProperties, transportProperties, turbulenceProperties
│   │   │   ├── momentumTransport
│   │   │   └── triSurface/            STL ファイル
│   │   └── system/
│   └── LKHD045MRF/
│       ├── 0.orig/
│       ├── constant/
│       │   ├── g, physicalProperties, transportProperties, turbulenceProperties
│       │   ├── momentumTransport
│       │   └── MRFProperties
│       │   ※ polyMesh はランタイム symlink のためアップロード不要
│       └── system/
│
├── mesh/                               ← メッシュ生成ジョブの出力（自動生成）
│   ├── latest.txt                      最新メッシュの GCS パス（ソルバーが参照）
│   └── mesh_<TIMESTAMP>/
│       ├── polyMesh/                   メッシュ本体（faces, points, faceZones 等）
│       ├── fvMesh/                     NCC スティッチャー用データ（polyFaces）
│       └── logs/                       メッシュ生成ログ
│
└── results/                            ← ソルバージョブの出力（自動生成）
    ├── latest.txt
    └── LKHD045_<TIMESTAMP>/
        ├── 0/, 0.orig/, 0.mesh/
        ├── constant/, system/
        └── mrf_logs/
```

**`cases/LKHD045/constant/polyMesh/` はアップロード不要**。
メッシュ生成ジョブが `mesh/mesh_<TIMESTAMP>/polyMesh/` に生成し、ソルバーが自動取得します。

---

## Docker イメージ詳解

2 種類のイメージを使います。どちらも `openfoam/openfoam11-paraview510` ベースです。

```dockerfile
FROM openfoam/openfoam11-paraview510
USER root   # ベースイメージは openfoam ユーザーのため root への切り替えが必須
RUN apt-get install -y google-cloud-cli
ENV OMPI_MCA_btl_vader_single_copy_mechanism=none  # Docker 内 OpenMPI クラッシュ回避
```

### メッシュ生成ジョブ（`Dockerfile.mesh`）

| 環境変数 | 必須 | デフォルト | 説明 |
|---------|------|-----------|------|
| `GCS_BUCKET` | **必須** | — | GCS バケット名 |
| `NCORES` | 任意 | `4` | MPI 並列コア数（snappyHexMesh に使用） |
| `GCS_MESH_PREFIX` | 任意 | `mesh` | メッシュ出力先プレフィックス |
| `CASE_NAME` | 任意 | `LKHD045` | ケース名 |

### ソルバージョブ（`Dockerfile.solver`）

| 環境変数 | 必須 | デフォルト | 説明 |
|---------|------|-----------|------|
| `GCS_BUCKET` | **必須** | — | GCS バケット名 |
| `NCORES` | 任意 | `4` | MPI 並列コア数 |
| `GCS_RESULT_PREFIX` | 任意 | `results` | 結果保存先プレフィックス |
| `MRF_END_TIME` | 任意 | `3000` | MRF foamRun の endTime（イテレーション数） |
| `GCS_MESH_PATH` | 任意 | `mesh/latest.txt` から自動取得 | メッシュの GCS パス（`mesh_<TS>/` まで） |

---

## 前提条件

### GCP プロジェクト

- 課金が有効な GCP プロジェクト
- 対象リージョン: `asia-northeast1`（東京）推奨

### 必要な API の有効化

| API | 用途 |
|-----|------|
| Vertex AI API (`aiplatform.googleapis.com`) | Custom Job 実行 |
| Artifact Registry API (`artifactregistry.googleapis.com`) | Docker イメージ管理 |
| Cloud Storage API (`storage.googleapis.com`) | ケースファイル・結果の格納 |

### サービスアカウント権限

Vertex AI Custom Job はデフォルトの Compute Engine サービスアカウントで実行されます。
`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com` に **Storage オブジェクト管理者** (`roles/storage.objectAdmin`) が付与されていることを確認してください。

---

## Step 1: GCS バケットの作成とケースファイルのアップロード

### 1-1. バケット作成

GCP コンソール → **Cloud Storage** → **バケットを作成**
- バケット名（グローバル一意）
- ロケーション: **リージョン** → `asia-northeast1`

### 1-2. ケースファイルのアップロード

上記「GCS ファイル構成」の `cases/` 以下の内容をアップロードします。

**アップロード不要なファイル:**

| ファイル/ディレクトリ | 除外理由 |
|--------------------|---------|
| `LKHD045/constant/polyMesh/` | メッシュ生成ジョブが生成 |
| `LKHD045/constant/fvMesh/` | createNonConformalCouples が生成 |
| `LKHD045/constant/extendedFeatureEdgeMesh/` | surfaceFeatureExtract が生成 |
| `LKHD045/constant/triSurface/*.eMesh` | surfaceFeatureExtract が生成 |
| `LKHD045MRF/constant/polyMesh` | ランタイム symlink（entrypoint_solver.sh が再作成） |
| `0/` | ランタイム作業ディレクトリ（restore0Dir で生成） |
| `log.*`, `processor*/`, `postProcessing/` | 実行時生成 |

---

## Step 2: Artifact Registry リポジトリの作成

GCP コンソール → **Artifact Registry** → **リポジトリを作成**
- 名前: `openfoam`
- 形式: **Docker**
- ロケーション: **リージョン** → `asia-northeast1`

---

## Step 3: Docker イメージのビルドと Push

### 3-1. Docker 認証設定

```bash
gcloud auth configure-docker asia-northeast1-docker.pkg.dev
```

### 3-2. イメージビルド & Push

```bash
REGISTRY="asia-northeast1-docker.pkg.dev/<PROJECT_ID>/openfoam"

# メッシュ生成ジョブ用
docker build --platform linux/amd64 \
    -t "${REGISTRY}/openfoam-mesh:latest" \
    -f docker/Dockerfile.mesh docker/
docker push "${REGISTRY}/openfoam-mesh:latest"

# ソルバージョブ用
docker build --platform linux/amd64 \
    -t "${REGISTRY}/openfoam-solver:latest" \
    -f docker/Dockerfile.solver docker/
docker push "${REGISTRY}/openfoam-solver:latest"
```

> **注意**: OpenFOAM の Docker イメージは Linux/amd64 専用です。ARM Mac 等でビルドする場合は
> `--platform linux/amd64` が必須です。Cloud Workstations (Linux/amd64 ネイティブ) を使うと高速です。

---

## Step 4: Vertex AI Custom Job の YAML 準備

`vertex_ai/job_mesh.yaml` と `vertex_ai/job_solver.yaml` の 2 箇所を書き換えます。

```yaml
imageUri: asia-northeast1-docker.pkg.dev/<PROJECT_ID>/openfoam/...  # PROJECT_ID を入力
- name: GCS_BUCKET
  value: your-openfoam-bucket  # 実際のバケット名に変更
```

必要に応じて `NCORES`（マシンの vCPU 数以下）、`MRF_END_TIME` を調整します。

---

## Step 5: Vertex AI Custom Job の実行

### 5-1. メッシュ生成ジョブ

```bash
gcloud ai custom-jobs create \
  --region=asia-northeast1 \
  --config=vertex_ai/job_mesh.yaml
```

完了すると `gs://<GCS_BUCKET>/mesh/latest.txt` が更新され、ソルバーが自動参照します。

### 5-2. ソルバージョブ（メッシュ生成完了後）

```bash
gcloud ai custom-jobs create \
  --region=asia-northeast1 \
  --config=vertex_ai/job_solver.yaml
```

> **特定のメッシュを指定する場合**: `job_solver.yaml` の `GCS_MESH_PATH` のコメントを外し、
> GCS コンソールで確認したパス（`gs://bucket/mesh/mesh_<TS>/`）を設定します。

### 5-3. 進捗監視

GCP コンソール → **Vertex AI** → **Training** → **カスタムジョブ** でステータス確認。
ジョブ詳細 → **ログを表示** でコンテナ出力をリアルタイム確認。

---

## Step 6: 計算結果のダウンロード

```bash
LATEST=$(gsutil cat gs://your-openfoam-bucket/results/latest.txt)
gsutil -m cp -r "${LATEST}" ./results/
```

または GCP コンソール → **Cloud Storage** → `results/LKHD045_<TIMESTAMP>/`

---

## ケース設定の詳細

### 境界条件（U）

| パッチ | LKHD045（0.orig/U） | LKHD045MRF（0.orig/U） |
|--------|--------------------|-----------------------|
| `impeller_HD0.45` | `movingWallVelocity` | `rotatingWallVelocity` |
| `shaft_HD0.45` | `movingWallVelocity` | `rotatingWallVelocity` |
| `reactor_HD0.45` | `noSlip` | `noSlip` |
| `baffle_HD0.45` | `noSlip` | `noSlip` |
| `AMI1`, `AMI2` | `movingWallSlipVelocity` | `zeroGradient` |
| NCC パッチ | `#includeEtc "caseDicts/setConstraintTypes"` | 同左 |

> **NCC パッチ** (`nonConformalCyclic_on_AMI1/2`、`nonConformalError_on_AMI1/2`) は 0-face 仮想パッチ。
> `#includeEtc "caseDicts/setConstraintTypes"` で自動処理されるため、個別記述は不要。

### value の注意事項（OF11 compound token 問題）

`value $internalField;` は `internalField` が nonuniform（再起動後など）の場合に
"compound has already been transferred from token" でクラッシュします。
`0.orig/` の全 BC に `value uniform <scalar/vector>;` で明示値を使用してください。

### MRFProperties（`LKHD045MRF/constant/MRFProperties`）

```cpp
MRF1
{
    cellZone            rotating;
    active              yes;
    nonRotatingPatches  (AMI1 AMI2);  // AMI への MRF ソース二重適用を防ぐ（必須）
    origin              (0 0 0);
    axis                (0 1 0);
    omega               -10.47;       // rad/s（dynamicMeshDict の omega と一致させること）
}
```

### fvSolution — LKHD045（PIMPLE ブロック）

```cpp
PIMPLE
{
    momentumPredictor   yes;
    correctPhi          yes;
    correctMeshPhi      no;    // solidBody + NCC では必ず no（yes にするとクラッシュ）
    nOuterCorrectors    7;
    nCorrectors         4;
    nNonOrthogonalCorrectors 3;
    pRefPoint   (0 0.06 0.15);
    pRefValue   0;
}
```

### fvSolution — LKHD045MRF（SIMPLE ブロック）

```cpp
SIMPLE
{
    nNonOrthogonalCorrectors 3;
    pRefPoint   (0 0.06 0.15);
    pRefValue   0;
    residualControl { p 1e-4; U 1e-4; "(k|epsilon)" 1e-4; }
}
```

### フィールドマッピング（Python internalField コピー）

`mapFields -consistent` は OF11 NCC メッシュでセグフォルトします（meshToMesh0 が 0-face 仮想パッチを処理できないため）。
`entrypoint_solver.sh` Step 6b では以下の Python ロジックで代替しています:

```python
# MRF の internalField + pimpleFoam の boundaryField を結合して 0/ に書き出す
src_before, _ = split_foam_field(mrf_field_text)     # header + internalField
_, tgt_boundary = split_foam_field(orig_field_text)  # boundaryField（0.orig/ から）
write(src_before + tgt_boundary)
```

対象フィールド: `U`, `p`, `k`, `epsilon`, `nut`

---

## 流体モデルの設定

流体物性は **両ケース共通** のファイルで管理します（必ず同じ内容に保つこと）:
- `LKHD045/constant/transportProperties`
- `LKHD045MRF/constant/transportProperties`

### ニュートン流体（水など）

```cpp
transportModel  Newtonian;
nu              [0 2 -1 0 0 0 0] 1e-06;
```

### 非ニュートン流体（powerLaw）

```cpp
transportModel  powerLaw;
powerLawCoeffs
{
    k       [0 2 -1 0 0 0 0] 1.686e-06;
    n       [0 0  0 0 0 0 0] 0.567;
    nuMin   [0 2 -1 0 0 0 0] 1e-09;
    nuMax   [0 2 -1 0 0 0 0] 1e-04;
}
```

---

## マシンタイプ別コスト目安

東京リージョン (`asia-northeast1`) の概算:

| マシンタイプ | vCPU | NCORES 推奨 | 8時間の概算コスト |
|------------|------|------------|-----------------|
| n1-standard-4 | 4 | 4 | 〜$1 USD |
| n1-standard-8 | 8 | 8 | 〜$2 USD |
| n1-standard-16 | 16 | 16 | 〜$4 USD |
| c2-standard-8 | 8 | 8 | 〜$3 USD（高クロック・計算向け） |

※ NCC の patchToPatch 再計算はシリアルで〜8.5秒/PIMPLE 反復。本番は並列実行を推奨。

---

## トラブルシューティング

### `GCS_BUCKET` エラーでジョブが FAILED

Vertex AI の環境変数設定を確認。`GCS_BUCKET` が未設定または空の場合に発生。

### `Cannot find file "points"` エラー

ソルバージョブが polyMesh を取得できていない。

1. メッシュ生成ジョブが正常完了しているか確認
2. GCS コンソールで `mesh/latest.txt` が存在するか確認
3. `GCS_MESH_PATH` を明示的に設定して再実行

### `faceZones が存在しません` エラー（メッシュ生成ジョブ）

snappyHexMesh が rotating faceZone を生成しなかった場合。

1. `mesh/<TS>/logs/log.snappyHexMesh` で `rotating` faceZone の作成ログを確認
2. `snappyHexMeshDict` の `refinementSurfaces` 設定を確認
3. blockMesh のベースメッシュが STL ジオメトリを包含しているか確認

### `"Face data requested from a non-face correction info"` クラッシュ

`fvSolution` の PIMPLE ブロックに `correctMeshPhi yes;` が設定されています。
solidBody 回転 + NCC では **`correctMeshPhi no;`** が必須です。

### `"compound has already been transferred from token"` クラッシュ

`0/` の BC に `value $internalField;` が残っています（再起動後などに発生）。
`0.orig/` の全 BC を `value uniform <値>;` の明示形式に修正してください。

### `There are not enough slots` エラー（mpirun）

`mpirun` に `--oversubscribe` が付いているか確認（`entrypoint_*.sh` には付与済み）。

### MRF foamRun が発散する

1. 緩和係数を下げる: `p: 0.3 → 0.2`, `U: 0.7 → 0.5`
2. `nNonOrthogonalCorrectors` を増やす: `3 → 5`
3. `MRF_END_TIME` を増やして収束まで待つ

### GCS 認証エラー（コンテナ内）

Compute Engine サービスアカウントに `roles/storage.objectAdmin` が付与されているか
GCP コンソール → **IAM と管理** → **IAM** で確認してください。
