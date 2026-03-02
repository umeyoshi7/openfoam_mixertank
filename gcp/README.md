# OpenFOAM on GCP — Vertex AI Custom Job デプロイ手順

## 概要

ローカルの OpenFOAM ケース（`LK-1_HD0.45_MRF` + `LK-1_HD0.45`）を Docker コンテナ化し、
Google Cloud Vertex AI Custom Job で実行します。
計算結果は Cloud Storage (GCS) に自動保存されます。

### 実行するワークフロー（コンテナ内で一括処理）

```
GCS からダウンロード
  → MRF simpleFoam (定常収束)
  → mapFields (MRF → pimpleFoam 初期値転写)
  → pimpleFoam (非定常計算)
  → 結果を GCS へアップロード
```

### ファイル構成

```
gcp/
├── README.md              本ファイル
├── submit_job.py          Vertex AI Custom Job 投入スクリプト (Python)
├── job_config.yaml        Vertex AI Custom Job 設定テンプレート (YAML)
├── upload_case.sh         ケースファイルを GCS へアップロード
├── download_results.sh    計算結果を GCS からダウンロード
├── build_push.sh          Docker ビルド & Artifact Registry へ Push
├── requirements.txt       Python 依存パッケージ
└── .env.example           環境変数テンプレート

docker/
├── Dockerfile             OpenFOAM v2012 + Cloud CLI コンテナ定義
└── entrypoint.sh          フルワークフロー実行スクリプト
```

---

## 前提条件

| ツール | バージョン目安 | 確認コマンド |
|--------|-------------|-------------|
| Docker Desktop | 24 以上 | `docker --version` |
| Google Cloud CLI | 最新 | `gcloud --version` |
| Python | 3.10 以上 | `python3 --version` |
| gsutil | gcloud 同梱 | `gsutil --version` |

---

## Step 0: 初期セットアップ（初回のみ）

### 0-1. 環境変数ファイルを作成

```bash
cp gcp/.env.example gcp/.env
```

`gcp/.env` を編集して各値を設定する:

```bash
PROJECT_ID=your-gcp-project-id    # GCP プロジェクト ID
REGION=asia-northeast1             # 使用するリージョン
BUCKET=your-openfoam-bucket        # GCS バケット名（一意である必要あり）
AR_REPO=openfoam                   # Artifact Registry リポジトリ名
IMAGE_NAME=openfoam-ami            # Docker イメージ名
IMAGE_TAG=latest                   # Docker タグ
NCORES=4                           # MPI コア数
MACHINE_TYPE=n1-standard-4         # Compute Engine マシンタイプ
```

以降の手順では毎回このファイルを読み込む:

```bash
source gcp/.env
```

### 0-2. GCP 認証

```bash
gcloud auth login
gcloud config set project "${PROJECT_ID}"
gcloud auth application-default login   # Python SDK 用
```

### 0-3. 必要な GCP API を有効化

```bash
gcloud services enable \
    aiplatform.googleapis.com \
    artifactregistry.googleapis.com \
    storage.googleapis.com \
    --project="${PROJECT_ID}"
```

### 0-4. GCS バケットを作成

```bash
gsutil mb -l "${REGION}" "gs://${BUCKET}"
```

### 0-5. Python 依存パッケージをインストール

```bash
pip install -r gcp/requirements.txt
```

---

## Step 1: Docker イメージをビルドして Artifact Registry へ Push

```bash
source gcp/.env
bash gcp/build_push.sh
```

**内部処理:**
1. Artifact Registry リポジトリを作成（初回のみ）
2. `gcloud auth configure-docker` で Docker 認証を設定
3. `docker build --platform linux/amd64` でイメージをローカルビルド
4. `docker push` で Artifact Registry へアップロード

**完了確認:**
```bash
gcloud artifacts docker images list \
    "${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}" \
    --project="${PROJECT_ID}"
```

> **補足**: Cloud Build は使用しません。ローカルの Docker でビルドします。
> ARM Mac などクロスプラットフォーム環境では `--platform linux/amd64` が必要です。

---

## 流体モデルの確認（アップロード前に必ず実施）

GCS にアップロードする前に、**両ケースの `constant/transportProperties`** が
目的の流体モデルに設定されていることを確認してください。

```bash
# 現在の設定を確認
grep "transportModel" LK-1_HD0.45_MRF/constant/transportProperties
grep "transportModel" LK-1_HD0.45/constant/transportProperties
# → 両ファイルが同じモデルを示すこと
```

### ニュートン流体（水など）に設定する場合

`LK-1_HD0.45_MRF/constant/transportProperties`（`LK-1_HD0.45/` 側も同様）:

```cpp
transportModel  Newtonian;

nu              [0 2 -1 0 0 0 0] 1e-06;
```

### 非ニュートン流体（疑塑性・powerLaw）に設定する場合

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

> パラメータの導出根拠・切り替え手順の詳細は `LK-1_HD0.45_MRF/README.md`
> の「流体モデルの設定」セクションを参照。

---

## Step 2: ケースファイルを GCS にアップロード

```bash
source gcp/.env
bash gcp/upload_case.sh
```

**アップロード先:**
```
gs://${BUCKET}/cases/LK-1_HD0.45/          ← polyMesh 実体を含む完全なケース
gs://${BUCKET}/cases/LK-1_HD0.45_MRF/      ← polyMesh シンボリックリンクを除外
```

**除外されるもの:**
- `processor*/` (並列分割結果)
- `log.*` (ログ)
- 計算済みタイムディレクトリ (`[0-9]*/`)
- `0.backup/`, `0.orig/`
- `LK-1_HD0.45_MRF/constant/polyMesh` (シンボリックリンクのため実体なし)

**完了確認:**
```bash
gsutil ls "gs://${BUCKET}/cases/"
```

---

## Step 3: Vertex AI Custom Job を投入

```bash
source gcp/.env
python gcp/submit_job.py \
    --project      "${PROJECT_ID}" \
    --region       "${REGION}" \
    --bucket       "${BUCKET}" \
    --image        "${IMAGE_URI}" \
    --ncores       "${NCORES}" \
    --machine-type "${MACHINE_TYPE}"
```

**主なオプション:**

| オプション | デフォルト | 説明 |
|-----------|-----------|------|
| `--ncores` | 4 | MPI コア数 |
| `--machine-type` | n1-standard-4 | Compute Engine マシンタイプ |
| `--mrf-end-time` | 3000 | MRF 定常計算の最大イテレーション |
| `--timeout-hours` | 24 | ジョブタイムアウト時間 |
| `--sync` | False | 完了まで待機する（デフォルトは非同期） |

**または YAML ファイルから gcloud コマンドで投入:**
```bash
source gcp/.env
envsubst < gcp/job_config.yaml > /tmp/job_config_expanded.yaml
gcloud ai custom-jobs create \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --display-name="openfoam-ami" \
    --config=/tmp/job_config_expanded.yaml
```

---

## Step 4: 進捗を確認

```bash
# 実行一覧の確認
gcloud ai custom-jobs list \
    --region="${REGION}" --project="${PROJECT_ID}"

# 特定ジョブの詳細
gcloud ai custom-jobs describe <JOB_ID> \
    --region="${REGION}" --project="${PROJECT_ID}"

# Cloud Logging でログを確認
gcloud logging read \
    "resource.type=ml_job" \
    --project="${PROJECT_ID}" --limit=50 --format="value(textPayload)"
```

**コンソール:**
```
https://console.cloud.google.com/vertex-ai/training/custom-jobs?project=<PROJECT_ID>
```

---

## Step 5: 計算結果をダウンロード

```bash
source gcp/.env
bash gcp/download_results.sh
```

最新の結果が `results/<TIMESTAMP>/` にダウンロードされます。

特定の結果を指定してダウンロードする場合:
```bash
bash gcp/download_results.sh "gs://${BUCKET}/results/LK-1_HD0.45_20260302_120000/"
```

**GCS 上の結果を確認:**
```bash
gsutil ls "gs://${BUCKET}/results/"
gsutil ls "gs://${BUCKET}/results/LK-1_HD0.45_<TIMESTAMP>/"
```

---

## ワンライナー実行（全ステップ）

初回セットアップ完了後:

```bash
source gcp/.env && \
bash gcp/build_push.sh && \
bash gcp/upload_case.sh && \
python gcp/submit_job.py \
    --project      "${PROJECT_ID}" \
    --region       "${REGION}" \
    --bucket       "${BUCKET}" \
    --image        "${IMAGE_URI}" \
    --ncores       "${NCORES}" \
    --machine-type "${MACHINE_TYPE}" \
    --sync   # 完了まで待機してからダウンロード
# ジョブ完了後:
bash gcp/download_results.sh
```

---

## コスト目安

Vertex AI Custom Job は実行時間に対してのみ課金されます（待機中は無料）。

| マシンタイプ | vCPU | メモリ | 実行時間 | 概算コスト |
|------------|------|-------|---------|-----------|
| n1-standard-4 | 4 | 15 GB | 8 時間 | 〜$1 USD |
| n1-standard-8 | 8 | 30 GB | 8 時間 | 〜$2 USD |
| n1-standard-16 | 16 | 60 GB | 8 時間 | 〜$4 USD |
| c2-standard-8 | 8 | 32 GB | 8 時間 | 〜$3 USD |

※ 東京リージョン (asia-northeast1) の概算。GCS 転送費用は別途。

---

## トラブルシューティング

### Docker ビルドが失敗する

```bash
# キャッシュなしでビルド
docker build --no-cache --platform linux/amd64 -t "${IMAGE_URI}" docker/

# ベースイメージを手動で確認
docker pull openfoam/openfoam2012-paraview56:latest
```

### ジョブがメモリ不足で終了する

より大きなマシンタイプを指定する:

```bash
python gcp/submit_job.py ... --machine-type n1-standard-16 --ncores 16
```

### `Cannot find file "points"` エラー (ログ内)

polyMesh のシンボリックリンク再作成に失敗しています。
`entrypoint.sh` の Step 3 を確認し、GCS に `LK-1_HD0.45/constant/polyMesh/` が
正しくアップロードされているか確認:

```bash
gsutil ls "gs://${BUCKET}/cases/LK-1_HD0.45/constant/polyMesh/"
```

### GCS への認証エラー

Vertex AI Custom Job は実行時にデフォルトサービスアカウントを使用します。
以下の権限が必要です:

```bash
# Vertex AI サービスアカウントに Storage 権限を付与
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:$(gcloud projects describe ${PROJECT_ID} \
        --format='value(projectNumber)')-compute@developer.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"
```

### 結果が GCS に見つからない

`latest.txt` を確認:
```bash
gsutil cat "gs://${BUCKET}/results/latest.txt"
```

結果ディレクトリを直接一覧表示:
```bash
gsutil ls "gs://${BUCKET}/results/"
```
