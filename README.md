# OpenFOAM 攪拌槽シミュレーション — GCP クラウド実行ガイド

## 概要

OpenFOAM v11 を使った攪拌槽内流れシミュレーションを GCP クラウド上で実行するためのガイドです。

**主目的**: MRF (Multiple Reference Frame) + `simpleFoam` で定常収束解を得て、
それを `pimpleFoam`（動的メッシュ + AMI）の初期値として使うことで、非定常計算の収束を大幅に高速化する。

- Docker コンテナを Artifact Registry に push し、Vertex AI Custom Job で実行
- **メッシュ生成ジョブ** と **ソルバージョブ** を分離し、それぞれ独立して実行可能
- 計算結果は Cloud Storage (GCS) に自動保存

---

## ケース命名規則

| 識別子 | 意味 |
|--------|------|
| `LK-1` | リアクター形状識別子 |
| `HD0.45` | 液面高さ比 H/D = 0.45 |
| `_MRF` サフィックス | MRF + simpleFoam 定常ケースを示す |

---

## 両ケースの対応関係

| 設定項目 | LK-1_HD0.45 (pimpleFoam) | LK-1_HD0.45_MRF (simpleFoam) |
|---------|--------------------------|-------------------------------|
| ソルバー | pimpleFoam | simpleFoam |
| 時間離散化 | 非定常 (Euler) | 定常 (steadyState) |
| 回転実装 | dynamicMesh solidBodyRotation + AMI | MRFProperties |
| impeller BC | movingWallVelocity | rotatingWallVelocity (omega=-10.47) |
| 圧力 BC | reactor_HD0.45: fixedValue 0 | 全壁: zeroGradient + pRefPoint |
| polyMesh | constant/polyMesh（実体） | constant/polyMesh → シンボリックリンク |

---

## ワークフロー全体図

```
[ローカル / Cloud Workstations]
        |
        | docker build & push (メッシュ用 + ソルバー用)
        v
[Artifact Registry]  ←── Docker イメージ × 2
        |
        | ① Vertex AI Custom Job（メッシュ生成）
        v
[Vertex AI Worker: メッシュ生成コンテナ]
  1. GCS から cases/LK-1_HD0.45 をダウンロード
  2. blockMesh → surfaceFeatureExtract → snappyHexMesh → createBaffles
  3. polyMesh を GCS へアップロード
        |
        v
[GCS: mesh/polyMesh_<timestamp>/]
        |
        | ② Vertex AI Custom Job（ソルバー）
        v
[Vertex AI Worker: ソルバーコンテナ]
  1. GCS から cases/* をダウンロード
  2. GCS から mesh/polyMesh をダウンロード
  3. MRF simpleFoam（定常収束）
  4. mapFields（MRF → pimpleFoam 初期値転写）
  5. pimpleFoam（非定常計算）
  6. 結果を GCS へアップロード
        |
        v
[GCS: results/LK-1_HD0.45_<timestamp>/]
        |
        | GCS コンソールから手動ダウンロード
        v
[ローカル]
```

---

## ディレクトリ構成

```
openfoam_mixertank/
├── README.md                    本ファイル
├── .gitignore
│
├── docker/
│   ├── Dockerfile.mesh          メッシュ生成ジョブ用コンテナ定義
│   ├── Dockerfile.solver        ソルバージョブ用コンテナ定義
│   ├── entrypoint_mesh.sh       メッシュ生成ワークフロースクリプト
│   └── entrypoint_solver.sh     ソルバーワークフロースクリプト
│
├── LK-1_HD0.45/                 非定常ケース (pimpleFoam + AMI)
│   ├── 0/                       初期条件（mapFields の書き込み先）
│   ├── 0.orig/                  均一初期値バックアップ
│   ├── constant/
│   │   ├── polyMesh/            メッシュ実体（.gitignore 除外）
│   │   └── dynamicMeshDict
│   └── system/
│
└── LK-1_HD0.45_MRF/             定常ケース (simpleFoam + MRF) ← 初期値生成用
    ├── 0.orig/                  初期条件（restore0Dir のコピー元）
    ├── constant/
    │   ├── polyMesh → ../../LK-1_HD0.45/constant/polyMesh  (シンボリックリンク)
    │   └── MRFProperties
    ├── system/
    ├── Allrun                   MRF 計算実行スクリプト（ローカル実行用）
    ├── Allclean                 クリーンアップスクリプト（ローカル実行用）
    └── mapToTransient.sh        mapFields 実行スクリプト（ローカル実行用）
```

---

## GCS ファイル構成

GCS バケット内のファイルは以下の 3 階層で管理します。

```
gs://<BUCKET>/
├── cases/                         ← ユーザーがアップロードするケースファイル
│   ├── LK-1_HD0.45/
│   │   ├── 0/                     mapFields の書き込み先（BC 構造が必要）
│   │   ├── 0.orig/                均一初期値バックアップ
│   │   ├── constant/
│   │   │   ├── dynamicMeshDict
│   │   │   ├── g
│   │   │   ├── transportProperties
│   │   │   ├── turbulenceProperties
│   │   │   └── triSurface/        STL ファイル（メッシュ生成ジョブが使用）
│   │   └── system/
│   │       ├── blockMeshDict
│   │       ├── controlDict
│   │       ├── createBafflesDict
│   │       ├── decomposeParDict
│   │       ├── fvSchemes
│   │       ├── fvSolution
│   │       ├── mapFieldsDict
│   │       ├── snappyHexMeshDict
│   │       └── surfaceFeatureExtractDict
│   └── LK-1_HD0.45_MRF/
│       ├── 0.orig/
│       ├── constant/
│       │   ├── g
│       │   ├── MRFProperties
│       │   ├── transportProperties
│       │   └── turbulenceProperties
│       │   ※ polyMesh はシンボリックリンクのためアップロード不要
│       │     （entrypoint_solver.sh がコンテナ内で自動再作成）
│       └── system/
│           ├── controlDict
│           ├── decomposeParDict
│           ├── fvSchemes
│           └── fvSolution
│
├── mesh/                          ← メッシュ生成ジョブの出力（自動生成）
│   ├── latest.txt                 最新メッシュの GCS パス（ソルバーが参照）
│   └── polyMesh_<TIMESTAMP>/      タイムスタンプ付きメッシュ（イミュータブル）
│       ├── boundary
│       ├── cellZones
│       ├── faceZones
│       ├── faces
│       ├── neighbour
│       ├── owner
│       ├── points
│       └── logs/                  メッシュ生成ログ
│           ├── log.blockMesh
│           ├── log.snappyHexMesh
│           └── log.checkMesh
│
└── results/                       ← ソルバージョブの出力（自動生成）
    ├── latest.txt                 最新結果の GCS パス
    └── LK-1_HD0.45_<TIMESTAMP>/   タイムスタンプ付き結果（イミュータブル）
        ├── 0/                     初期条件（mapFields 後）
        ├── 0.025/                 最初の書き込みタイムステップ
        ├── 0.05/
        ├── ...
        ├── constant/
        ├── system/
        └── mrf_logs/              MRF 計算ログ
```

**`cases/LK-1_HD0.45/constant/polyMesh/` はアップロード不要**。
メッシュ生成ジョブが `mesh/` に生成し、ソルバージョブはそこから取得します。

---

## Docker イメージ詳解

2 種類のイメージを使います。どちらも `openfoam/openfoam11-paraview510` ベースです。

### 共通構成

```dockerfile
FROM openfoam/openfoam11-paraview510
USER root   # ← ベースイメージは openfoam ユーザーのため root への切り替えが必須
RUN apt-get install -y google-cloud-cli
ENV OMPI_MCA_btl_vader_single_copy_mechanism=none  # Docker 内 OpenMPI クラッシュ回避
ENTRYPOINT ["/entrypoint_<mesh|solver>.sh"]
```

### メッシュ生成ジョブ（`Dockerfile.mesh`）

`entrypoint_mesh.sh` が受け取る環境変数:

| 環境変数 | 必須 | デフォルト | 説明 |
|---------|------|-----------|------|
| `GCS_BUCKET` | **必須** | — | GCS バケット名 |
| `NCORES` | 任意 | `4` | MPI 並列コア数（snappyHexMesh に使用） |
| `GCS_MESH_PREFIX` | 任意 | `mesh` | メッシュ出力先プレフィックス |
| `CASE_NAME` | 任意 | `LK-1_HD0.45` | ケース名 |

### ソルバージョブ（`Dockerfile.solver`）

`entrypoint_solver.sh` が受け取る環境変数:

| 環境変数 | 必須 | デフォルト | 説明 |
|---------|------|-----------|------|
| `GCS_BUCKET` | **必須** | — | GCS バケット名 |
| `NCORES` | 任意 | `4` | MPI 並列コア数 |
| `GCS_RESULT_PREFIX` | 任意 | `results` | 結果保存先プレフィックス |
| `MRF_END_TIME` | 任意 | `3000` | MRF simpleFoam の最大イテレーション数 |
| `GCS_MESH_PATH` | 任意 | ― | polyMesh の GCS パス（省略時は `mesh/latest.txt` から自動取得） |

---

## 前提条件

### GCP プロジェクト

- 課金が有効な GCP プロジェクト
- 対象リージョン: `asia-northeast1`（東京）推奨

### 必要な API の有効化

GCP コンソール → **API とサービス** → **API を有効にする** から以下を有効化:

| API | 用途 |
|-----|------|
| Vertex AI API (`aiplatform.googleapis.com`) | Custom Job 実行 |
| Artifact Registry API (`artifactregistry.googleapis.com`) | Docker イメージ管理 |
| Cloud Storage API (`storage.googleapis.com`) | ケースファイル・結果の格納 |

### サービスアカウント権限の確認

Vertex AI Custom Job はデフォルトの Compute Engine サービスアカウントで実行されます。
GCS への読み書き権限として `roles/storage.objectAdmin` が必要です。

GCP コンソール → **IAM と管理** → **IAM** で
`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com` に
**Storage オブジェクト管理者** ロールが付与されていることを確認してください。

---

## Step 1: GCS バケットの作成とケースファイルのアップロード

### 1-1. GCS バケットを作成（Cloud Storage コンソール）

1. GCP コンソール → **Cloud Storage** → **バケットを作成**
2. バケット名を入力（例: `your-openfoam-bucket`）— グローバルで一意である必要あり
3. ロケーションタイプ: **リージョン** → `asia-northeast1`（東京）
4. **作成** をクリック

### 1-2. 流体モデルの確認（アップロード前に必ず実施）

GCS にアップロードする前に、**両ケースの `constant/transportProperties`** が
目的の流体モデルに設定されていることを確認してください（「流体モデルの設定」セクション参照）。

### 1-3. ケースファイルをアップロード（GCS コンソール）

GCP コンソール → **Cloud Storage** → バケット名 から、
`cases/` フォルダを作成し、上記「GCS ファイル構成」に従ってアップロードします。

**アップロード不要なファイル:**

| ファイル/ディレクトリ | 除外理由 |
|--------------------|---------|
| `LK-1_HD0.45/constant/polyMesh/` | メッシュ生成ジョブが生成し GCS の `mesh/` に保存 |
| `LK-1_HD0.45_MRF/constant/polyMesh` | シンボリックリンク（実体なし）、entrypoint_solver.sh が再作成 |
| `0.backup/` | mapFields 実行時にコンテナ内で自動生成 |
| `log.*` | 実行時生成 |
| `10/`, `20/`, ... | 計算済みタイムディレクトリ |
| `processor*/` | 並列分割結果 |
| `postProcessing/` | 後処理出力 |

---

## Step 2: Artifact Registry リポジトリの作成

1. GCP コンソール → **Artifact Registry** → **リポジトリを作成**
2. 設定を入力:
   - 名前: `openfoam`
   - 形式: **Docker**
   - ロケーションタイプ: **リージョン** → `asia-northeast1`
3. **作成** をクリック

---

## Step 3: Docker イメージのビルドと Artifact Registry への Push

### 3-1. Cloud Workstations のワークステーション作成（GUI）

1. GCP コンソール → **Cloud Workstations** → **ワークステーション構成を作成**
2. マシンタイプ: `e2-standard-4`（Docker ビルド用）
3. コンテナイメージ: デフォルト（Code OSS）
4. **作成** → ワークステーションを起動

> **なぜ Cloud Workstations を使うか**: OpenFOAM の Docker イメージは Linux/amd64 専用のため、
> ARM Mac などのローカル環境ではクロスビルドが必要で時間がかかります。
> Cloud Workstations は Linux/amd64 ネイティブ環境なので高速にビルドできます。

### 3-2. リポジトリをクローン（ターミナル）

Cloud Workstations のターミナルで:

```bash
git clone https://github.com/<YOUR_ORG>/openfoam_mixertank.git
cd openfoam_mixertank
```

### 3-3. Docker 認証設定

```bash
gcloud auth configure-docker asia-northeast1-docker.pkg.dev
```

### 3-4. イメージビルド & Push（2 種類）

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

### 3-5. イメージ確認（Console GUI）

GCP コンソール → **Artifact Registry** → **openfoam** リポジトリ →
`openfoam-mesh` と `openfoam-solver` の 2 つのイメージが表示されることを確認。

---

## Step 4: Vertex AI Custom Training Job の作成と実行（GUI）

メッシュ生成ジョブとソルバージョブを**順番に**実行します。
メッシュ生成が完了してから（または `GCS_MESH_PATH` を指定して）ソルバーを実行します。

### 4-1. メッシュ生成ジョブ

GCP コンソール → **Vertex AI** → **Training** → **カスタムジョブ** → **作成**

**トレーニングコンテナ** セクション:

- **コンテナイメージ URI**:
  ```
  asia-northeast1-docker.pkg.dev/<PROJECT_ID>/openfoam/openfoam-mesh:latest
  ```

- **環境変数**:

  | 名前 | 値 | 説明 |
  |------|----|------|
  | `GCS_BUCKET` | `your-openfoam-bucket` | GCS バケット名（必須） |
  | `NCORES` | `8` | MPI コア数 |
  | `GCS_MESH_PREFIX` | `mesh` | メッシュ出力先（デフォルト値でも可） |

**ワーカープール**: マシンタイプ `n1-standard-8`、レプリカ数 `1`

**開始** をクリック。完了すると `gs://<BUCKET>/mesh/latest.txt` が生成されます。

### 4-2. ソルバージョブ

GCP コンソール → **Vertex AI** → **Training** → **カスタムジョブ** → **作成**

**トレーニングコンテナ** セクション:

- **コンテナイメージ URI**:
  ```
  asia-northeast1-docker.pkg.dev/<PROJECT_ID>/openfoam/openfoam-solver:latest
  ```

- **環境変数**:

  | 名前 | 値 | 説明 |
  |------|----|------|
  | `GCS_BUCKET` | `your-openfoam-bucket` | GCS バケット名（必須） |
  | `NCORES` | `8` | MPI コア数 |
  | `GCS_RESULT_PREFIX` | `results` | 結果保存先（デフォルト値でも可） |
  | `MRF_END_TIME` | `3000` | MRF 最大イテレーション数 |
  | `GCS_MESH_PATH` | *(省略可)* | 省略時は `mesh/latest.txt` から自動取得 |

> `GCS_MESH_PATH` を明示する場合は GCS コンソールで `mesh/polyMesh_<TIMESTAMP>/` のパスを確認してコピーします。
> 例: `gs://your-openfoam-bucket/mesh/polyMesh_20260415_120000/`

**ワーカープール**: マシンタイプ `n1-standard-8`、レプリカ数 `1`

> `NCORES` の値はマシンの vCPU 数以下に設定してください。
> `n1-standard-8` なら `NCORES=8`、`n1-standard-16` なら `NCORES=16`。

---

## Step 5: 進捗監視（GUI + Logging）

GCP コンソール → **Vertex AI** → **Training** → **カスタムジョブ** で
ジョブのステータス（実行中・成功・失敗）を確認。

ジョブ詳細ページ → **ログを表示** でコンテナの出力をリアルタイム確認。

---

## Step 6: 計算結果のダウンロード

GCP コンソール → **Cloud Storage** → バケット名 → `results/` フォルダ →
`LK-1_HD0.45_<TIMESTAMP>/` ディレクトリに計算結果が格納されています。

`results/latest.txt` に最新結果の GCS パスが記録されています。

GCS コンソールの **ダウンロード** ボタン、または `gsutil` を使って手元にダウンロードしてください:

```bash
# latest.txt から最新パスを取得してダウンロード
LATEST=$(gsutil cat gs://your-openfoam-bucket/results/latest.txt)
gsutil -m cp -r "${LATEST}" ./results/
```

---

## マシンタイプ別コスト目安

Vertex AI Custom Job は実行時間のみ課金（待機中は無料）。
東京リージョン (`asia-northeast1`) の概算:

| マシンタイプ | vCPU | メモリ | NCORES 推奨 | 8時間の概算コスト |
|------------|------|-------|------------|-----------------|
| n1-standard-4 | 4 | 15 GB | 4 | 〜$1 USD |
| n1-standard-8 | 8 | 30 GB | 8 | 〜$2 USD |
| n1-standard-16 | 16 | 60 GB | 16 | 〜$4 USD |
| c2-standard-8 | 8 | 32 GB | 8 | 〜$3 USD（高クロック・計算向け） |

※ GCS 転送費用は別途。

---

## MRF + simpleFoam → pimpleFoam 初期値生成

### なぜこの手順が有効か

| 起動方法 | pimpleFoam 1 ステップ目の U 初期残差 |
|---------|--------------------------------------|
| ゼロ初期値 | ~1.0（最大値） |
| MRF解（20 iter）→ mapFields 後 | ~2.3e-4 |
| MRF解（収束済み 3000 iter）→ mapFields 後 | さらに低い値が期待される |

初期残差が低いほど非定常計算の立ち上がりが安定・高速になります。

### ローカルでの実行手順

#### Step 1: MRF 定常計算

```sh
cd LK-1_HD0.45_MRF
./Allrun
```

内部処理:
1. `constant/polyMesh` のシンボリックリンクを作成（未作成の場合のみ）
2. `0/` を `0.orig/` からリセット（`restore0Dir`）
3. `decomposePar` で並列分割
4. `simpleFoam -parallel` で定常計算
5. `reconstructPar -latestTime` で最終タイムを再合成

**収束の目安**: 全残差（U, p, k, epsilon）が `1e-4` 以下

```sh
# 収束状況の確認
grep -E "^Time =|Solving for Ux.*Initial" log.simpleFoam | tail -30
```

`residualControl` の閾値（`1e-4`）に達すると「SIMPLE solution converged」と表示されて自動停止。
`endTime=3000` まで達した場合は残差トレンドを目視確認してください。

#### Step 2: フィールドマッピング

**必ず `LK-1_HD0.45_MRF/` 内から `./` 形式で実行**:

```sh
cd LK-1_HD0.45_MRF
./mapToTransient.sh
```

処理内容:
1. 最新タイムステップを自動検出（`foamListTimes -latestTime`）
2. `LK-1_HD0.45/0/` を `LK-1_HD0.45/0.backup/` にバックアップ
3. `mapFields -consistent` でフィールドを転写

#### Step 3: マッピング結果の確認

```sh
# U の internalField が非ゼロであることを確認
grep -A4 "^internalField" ../LK-1_HD0.45/0/U | head -6

# BC 型が pimpleFoam 用のまま保持されていることを確認
grep -A2 "impeller_HD0.45" ../LK-1_HD0.45/0/U
# → type movingWallVelocity であること（rotatingWallVelocity になっていないこと）
```

#### Step 4: pimpleFoam 実行

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

simpleFoam では圧力参照を `fvSolution/SIMPLE/pRefPoint` で与えるため、全壁を `zeroGradient` に統一します。

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

流体物性は **両ケース共通** のファイルで設定します:

- `LK-1_HD0.45_MRF/constant/transportProperties`
- `LK-1_HD0.45/constant/transportProperties`

> 両ファイルを**必ず同じ内容**に保つこと。片方だけ変更すると
> MRF 解と pimpleFoam 解で異なる物性が使われます。

### ニュートン流体（水など）

```cpp
transportModel  Newtonian;

nu              [0 2 -1 0 0 0 0] 1e-06;   // 動粘度 [m²/s]（水 20°C）
```

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

```
γ̇ = 160 u   [s⁻¹]  （先端速度 → せん断速度、無限媒体 Couette 近似）

μ [Pa·s] ≈ 1.352e-2 × γ̇^(-0.433)
  → K = 1.352e-2 Pa·s^n,  n = 0.567
  → k = K/ρ = 1.352e-2 / 8020 = 1.686e-6 m²/s^n
```

---

## ファイル変更時の確認事項

| 変更対象 | 確認事項 |
|---------|---------|
| `MRFProperties` | `omega`, `axis`, `origin` を `dynamicMeshDict` と一致させること |
| `0/U` の `impeller_HD0.45` BC | MRF ケース: `rotatingWallVelocity` / pimpleFoam ケース: `movingWallVelocity`（別々に管理） |
| `decomposeParDict` の並列数 | Vertex AI ジョブの `NCORES` 環境変数で動的に上書きされる |
| `transportProperties` | 両ケース（MRF・pimpleFoam）を**必ず同じ内容**に保つ |

---

## 注意事項

### mapFields の引数順序

```sh
# 構文: mapFields <sourceCase> [OPTIONS] [-case <dstCase>]
# -case が target（転写先）、第1引数が source（転写元）

# 正しい（LK-1_HD0.45_MRF/ から実行、MRF → pimpleFoam）
mapFields . -consistent -sourceTime 3000 -case ../LK-1_HD0.45

# 誤り（引数逆転、pimpleFoam → MRF になる）
mapFields ../LK-1_HD0.45 -consistent -sourceTime 3000 -case .
```

### mapFields は BC 型を保持する

`mapFields -consistent` は**値のみコピー**し、BC の `type` は書き換えない。
→ `impeller_HD0.45: movingWallVelocity` はマッピング後も維持される（設計通りの動作）。

### AMI と MRF の共存

`MRFProperties` で `nonRotatingPatches (AMI1 AMI2)` を指定すること。
→ AMI パッチへの MRF ソース項の二重適用を防ぐ（指定がないと解が不正になる）。

### シンボリックリンクのパス

`constant/polyMesh` のシンボリックリンクは「リンク自体の位置からの相対パス」で解決される。

```
constant/polyMesh → ../../LK-1_HD0.45/constant/polyMesh
                    ^^
                    constant/ から2段上 = リポジトリルートディレクトリ
```

`../`（1段）では解決先が正しくならずエラーになる。

### mapToTransient.sh の実行形式

```sh
# 正しい: ${0%/*} がスクリプトのディレクトリに展開される
./mapToTransient.sh

# 誤り: ${0%/*} が "mapToTransient.sh" になり cd が失敗する
bash mapToTransient.sh
```

### Windows (WSL) 環境での注意

- `pimpleFoam` は動的メッシュ + AMI の AMI 再構築を毎ステップ行うため、
  大規模メッシュのシリアル計算は非常に低速。
  実計算では並列（`decomposePar` + `mpirun`）を使用すること。
- Windows の NTFS ファイルシステム上での OpenFOAM の I/O は WSL ネイティブより低速。
  可能であれば WSL のホームディレクトリ（`~/OpenFOAM/...`）でケースを実行することを推奨。

---

## 他のケースへの適用（汎用手順）

新規 MRF ケース作成時に変更が必要なファイル:

| ファイル | 変更箇所 |
|---------|---------|
| `constant/MRFProperties` | `cellZone`, `omega`, `axis`, `origin`, `nonRotatingPatches` |
| `0/U` | 回転壁の `omega`, `axis`, `origin` |
| `fvSolution` | `SIMPLE/pRefPoint`（メッシュ内の点） |
| `mapToTransient.sh` | `TRANSIENT_CASE` 変数（相対パス） |
| `Allrun` | シンボリックリンクのパス、並列数 `-np` |
| `system/mapFieldsDict`（pimpleFoam側） | `patchMap` のパッチ名リスト |

`omega` の符号確認: `dynamicMeshDict` の `omega` と `MRFProperties` の `omega` を一致させること。

---

## トラブルシューティング

### ジョブが `FAILED` になる（ログに `GCS_BUCKET` エラー）

Vertex AI の環境変数設定を確認。`GCS_BUCKET` が未設定か空の場合に発生。

### `Cannot find file "points"` エラー（コンテナログ内）

ソルバージョブが polyMesh を取得できていない可能性。

1. メッシュ生成ジョブが正常完了しているか確認
2. GCS コンソールで `mesh/latest.txt` が存在するか確認
3. `GCS_MESH_PATH` を明示的に設定して再実行

### `faceZones が存在しません` エラー（メッシュ生成ジョブ）

`snappyHexMesh` が rotating faceZone を生成しなかった場合。

1. `mesh/<timestamp>/logs/log.snappyHexMesh` を確認
2. `snappyHexMeshDict` の `refinementSurfaces` / `addLayers` 設定を確認
3. blockMesh のベースメッシュが STL ジオメトリを包含しているか確認

### `There are not enough slots` エラー（mpirun）

OpenMPI のスロット数不足。`entrypoint_*.sh` の `mpirun` に `--oversubscribe` が付いているか確認。

### ジョブがメモリ不足で終了する

Vertex AI コンソールで Custom Job を再作成し、より大きなマシンタイプ（`n1-standard-8` など）を選択。
`NCORES` 環境変数も合わせて変更する。

### GCS への認証エラー（コンテナ内）

Compute Engine サービスアカウントに `roles/storage.objectAdmin` が付与されているか、
GCP コンソール → **IAM と管理** → **IAM** で確認してください。

### simpleFoam が発散する

1. 緩和係数を下げる: `p: 0.3 → 0.2`, `U: 0.7 → 0.5`
2. `nNonOrthogonalCorrectors` を増やす: `3 → 5`
3. 初期の `epsilon` bounding メッセージは正常（数ステップで消える）

### mapFields 後に 0/U が uniform (0 0 0) のまま

`mapFields` の source/target が逆になっています。
`mapToTransient.sh` または `entrypoint_solver.sh` の引数順序を確認してください（上記「注意事項」参照）。

### pimpleFoam で AMI 重みが 1 からずれる警告

`AMI: Patch target sum(weights) min:0.99 max:1.01` 程度は正常範囲。
`min < 0.9` になる場合は AMI メッシュの品質を確認すること。
