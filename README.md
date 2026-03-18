# OpenFOAM 攪拌槽シミュレーション — GCP クラウド実行ガイド

## 概要

OpenFOAM v2012 を使った攪拌槽内流れシミュレーションを GCP クラウド上で実行するためのガイドです。

- **MRF + simpleFoam** で定常解を得て、`pimpleFoam`（動的メッシュ + AMI）の初期値として使用
- Docker コンテナを Artifact Registry に push し、Vertex AI Custom Job で実行
- 計算結果は Cloud Storage (GCS) に自動保存

---

## ワークフロー全体図

```
[ローカル / Cloud Workstations]
        |
        | docker build & push
        v
[Artifact Registry]  ←── Docker イメージ保存
        |
        | Vertex AI Custom Job 実行
        v
[Vertex AI Worker (コンテナ内)]
  1. GCS からケースファイルをダウンロード
  2. polyMesh シンボリックリンク再作成
  3. MRF simpleFoam（定常収束）
  4. mapFields（MRF → pimpleFoam 初期値転写）
  5. pimpleFoam（非定常計算）
  6. 結果を GCS へアップロード
        |
        v
[Cloud Storage (GCS)]  ←── 結果・ログ保存
        |
        | download_results.sh
        v
[ローカル results/]
```

---

## ディレクトリ構成

```
openfoam_mixertank/
├── README.md                    本ファイル（GCP 実行ガイド）
├── CLAUDE.md                    Claude Code 向けプロジェクトコンテキスト
├── .gitignore
│
├── docker/
│   ├── Dockerfile               コンテナ定義
│   └── entrypoint.sh            フルワークフロー実行スクリプト
│
├── gcp/
│   ├── README.md                GCP デプロイ詳細手順（CLI 中心）
│   ├── job_config.yaml          Vertex AI Custom Job 設定テンプレート
│   ├── upload_case.sh           ケースファイルを GCS へアップロード
│   ├── download_results.sh      計算結果を GCS からダウンロード
│   └── .env.example             環境変数テンプレート
│
├── LK-1_HD0.45/                 非定常ケース (pimpleFoam + AMI)
│   ├── 0.orig/                  初期条件
│   ├── constant/
│   │   ├── polyMesh/            メッシュ実体（.gitignore 除外）
│   │   └── dynamicMeshDict
│   └── system/
│
└── LK-1_HD0.45_MRF/             定常ケース (simpleFoam + MRF) ← 初期値生成用
    ├── 0.orig/                  初期条件
    ├── constant/
    │   ├── polyMesh → ../../LK-1_HD0.45/constant/polyMesh  (シンボリックリンク)
    │   └── MRFProperties
    ├── system/
    ├── Allrun                   MRF 計算実行スクリプト
    ├── Allclean                 クリーンアップスクリプト
    ├── mapToTransient.sh        mapFields 実行スクリプト
    └── README.md                MRF ケース詳細説明
```

---

## Dockerfile 詳解

`docker/Dockerfile` の各命令の説明:

```dockerfile
# ベースイメージ: openfoam.com 公式イメージ (OpenFOAM v2012 + ParaView 5.6)
# /opt/openfoam2012/ に OpenFOAM がインストール済み
FROM openfoam/openfoam2012-paraview56:latest
```

```dockerfile
# Google Cloud CLI を apt 経由でインストール
# - curl, gnupg: GPG キーの取得に使用
# - google-cloud-cli: gsutil (GCS 操作) を含む
RUN apt-get update && apt-get install -y ... google-cloud-cli
```

```dockerfile
# google-cloud-storage Python クライアント（将来の拡張用）
RUN pip3 install google-cloud-storage==2.14.0
```

```dockerfile
# entrypoint.sh をコンテナ内にコピーし実行権限を付与
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

`entrypoint.sh` は以下の環境変数を受け取り、フルワークフローを自動実行します:

| 環境変数 | 必須 | デフォルト | 説明 |
|---------|------|-----------|------|
| `GCS_BUCKET` | 必須 | — | GCS バケット名 |
| `NCORES` | 任意 | `4` | MPI コア数 |
| `GCS_RESULT_PREFIX` | 任意 | `results` | GCS 結果プレフィックス |
| `MRF_END_TIME` | 任意 | `3000` | MRF 計算の最大イテレーション数 |

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

または CLI で一括有効化:
```bash
gcloud services enable \
    aiplatform.googleapis.com \
    artifactregistry.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}"
```

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

### 1-2. 環境変数ファイルを作成

```bash
cp gcp/.env.example gcp/.env
# gcp/.env を編集して PROJECT_ID, REGION, BUCKET などを設定
source gcp/.env
```

### 1-3. ケースファイルをアップロード（upload_case.sh）

```bash
source gcp/.env
bash gcp/upload_case.sh
```

アップロード先:
```
gs://${BUCKET}/cases/LK-1_HD0.45/        ← polyMesh 実体を含む完全なケース
gs://${BUCKET}/cases/LK-1_HD0.45_MRF/   ← polyMesh シンボリックリンクを除外
```

> **注意**: `LK-1_HD0.45_MRF/constant/polyMesh` はシンボリックリンクのため
> GCS にはアップロードしません。`entrypoint.sh` の Step 3 でコンテナ内に再作成されます。

---

## Step 2: Artifact Registry リポジトリの作成

### Console GUI 手順

1. GCP コンソール → **Artifact Registry** → **リポジトリを作成**
2. 設定を入力:
   - 名前: `openfoam`
   - 形式: **Docker**
   - ロケーションタイプ: **リージョン** → `asia-northeast1`
3. **作成** をクリック

---

## Step 3: Cloud Workstations でのセットアップと Docker イメージのビルド

### 3-1. Cloud Workstations のワークステーション作成（GUI）

1. GCP コンソール → **Cloud Workstations** → **ワークステーション構成を作成**
2. マシンタイプ: `e2-standard-4`（Docker ビルド用）
3. コンテナイメージ: デフォルト（Code OSS）
4. **作成** → ワークステーションを起動

> **なぜ Cloud Workstations を使うか**: OpenFOAM の Docker イメージは Linux/amd64 専用のため、
> ARM Mac などのローカル環境では `--platform linux/amd64` のクロスビルドが必要で時間がかかります。
> Cloud Workstations は Linux/amd64 ネイティブ環境なので高速にビルドできます。

### 3-2. リポジトリをクローン（ターミナル）

Cloud Workstations のターミナルで:

```bash
git clone https://github.com/<YOUR_ORG>/openfoam_mixertank.git
cd openfoam_mixertank
```

### 3-3. 環境変数の設定と Docker 認証（ターミナル）

```bash
cp gcp/.env.example gcp/.env
# gcp/.env を編集して PROJECT_ID, REGION, BUCKET などを設定
source gcp/.env

# Artifact Registry への Docker 認証
gcloud auth login
gcloud config set project "${PROJECT_ID}"
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

### 3-4. Docker ビルド & Artifact Registry へ Push（ターミナル）

```bash
source gcp/.env
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# ビルド（linux/amd64 を明示）
docker build --platform linux/amd64 -t "${IMAGE_URI}" docker/

# Artifact Registry へ Push
docker push "${IMAGE_URI}"

echo "Push 完了: ${IMAGE_URI}"
```

### 3-5. イメージ確認（Console GUI）

GCP コンソール → **Artifact Registry** → **openfoam** リポジトリ →
`openfoam-ami` イメージが表示されることを確認。

---

## Step 4: Vertex AI Custom Training Job の作成と実行（GUI）

### 4-1. カスタムジョブを新規作成

GCP コンソール → **Vertex AI** → **Training** → **カスタムジョブ** → **作成**

### 4-2. コンテナ設定（イメージ URI、環境変数）

**トレーニングコンテナ** セクション:

- **コンテナイメージ URI**:
  ```
  asia-northeast1-docker.pkg.dev/<PROJECT_ID>/openfoam/openfoam-ami:latest
  ```
  フォーマット: `REGION-docker.pkg.dev/PROJECT_ID/REPO/IMAGE:TAG`

- **環境変数** (+ ボタンで追加):

  | 名前 | 値 | 説明 |
  |------|----|------|
  | `GCS_BUCKET` | `your-openfoam-bucket` | GCS バケット名（必須） |
  | `NCORES` | `4` | MPI コア数 |
  | `GCS_RESULT_PREFIX` | `results` | GCS 結果プレフィックス |
  | `MRF_END_TIME` | `3000` | MRF 計算の最大イテレーション数 |

### 4-3. マシンタイプ・コア数の選択

**ワーカープール** セクション:

| 設定項目 | 推奨値 | 説明 |
|---------|-------|------|
| マシンタイプ | `n1-standard-4` | 4 vCPU / 15 GB メモリ |
| レプリカ数 | `1` | シングルノード実行 |

> `NCORES` の値はマシンの vCPU 数以下に設定してください。
> `n1-standard-4` なら `NCORES=4`、`n1-standard-8` なら `NCORES=8`。

### 4-4. ジョブ実行

**開始** をクリックしてジョブを投入。

---

## Step 5: 進捗監視（GUI + Logging）

### コンソール GUI での確認

GCP コンソール → **Vertex AI** → **Training** → **カスタムジョブ** で
ジョブのステータス（実行中・成功・失敗）を確認。

### Cloud Logging でのログ確認

ジョブ詳細ページ → **ログを表示** で `entrypoint.sh` の出力をリアルタイム確認。

または CLI で:
```bash
source gcp/.env
gcloud logging read \
    "resource.type=ml_job" \
    --project="${PROJECT_ID}" --limit=50 --format="value(textPayload)"
```

---

## Step 6: 計算結果のダウンロード

### 6-1. Cloud Storage コンソールで確認

GCP コンソール → **Cloud Storage** → バケット名 → `results/` フォルダ →
`LK-1_HD0.45_<TIMESTAMP>/` ディレクトリに計算結果が格納されていることを確認。

### 6-2. download_results.sh でローカルへダウンロード

```bash
source gcp/.env
bash gcp/download_results.sh
```

最新の結果が `results/<TIMESTAMP>/` にダウンロードされます。

特定のタイムスタンプを指定:
```bash
bash gcp/download_results.sh "gs://${BUCKET}/results/LK-1_HD0.45_20260302_120000/"
```

---

## 環境変数リファレンス（entrypoint.sh の引数）

Vertex AI Custom Job の「環境変数」フィールドに設定する値:

| 環境変数 | 必須 | デフォルト | 説明 |
|---------|------|-----------|------|
| `GCS_BUCKET` | **必須** | — | GCS バケット名（例: `your-openfoam-bucket`） |
| `NCORES` | 任意 | `4` | MPI 並列コア数。マシンの vCPU 数以下に設定 |
| `GCS_RESULT_PREFIX` | 任意 | `results` | GCS 上の結果保存先プレフィックス |
| `MRF_END_TIME` | 任意 | `3000` | MRF simpleFoam の最大イテレーション数 |

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

## トラブルシューティング

### Docker Push が `denied` エラーになる

```bash
# Artifact Registry への認証を再設定
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
# 認証情報を更新
gcloud auth login
```

### ジョブが `FAILED` になる（ログに `GCS_BUCKET` エラー）

Vertex AI の環境変数設定を確認。`GCS_BUCKET` が未設定か空の場合に発生。

### `Cannot find file "points"` エラー（コンテナログ内）

`upload_case.sh` が `LK-1_HD0.45/constant/polyMesh/` を正しくアップロードしていない可能性:

```bash
gsutil ls "gs://${BUCKET}/cases/LK-1_HD0.45/constant/polyMesh/"
```

ファイルが存在しない場合は `upload_case.sh` を再実行。

### ジョブがメモリ不足で終了する

Vertex AI コンソールで Custom Job を再作成し、より大きなマシンタイプ（`n1-standard-8` など）を選択。
`NCORES` 環境変数も合わせて変更する。

### GCS への認証エラー（コンテナ内）

Compute Engine サービスアカウントに `roles/storage.objectAdmin` が付与されているか確認:

```bash
# IAM 設定を確認
gcloud projects get-iam-policy "${PROJECT_ID}" \
    --flatten="bindings[].members" \
    --format="table(bindings.role, bindings.members)" \
    --filter="bindings.members:compute@developer"
```

### 結果が GCS に見つからない

```bash
# 最新結果パスを確認
gsutil cat "gs://${BUCKET}/results/latest.txt"

# 結果一覧
gsutil ls "gs://${BUCKET}/results/"
```
