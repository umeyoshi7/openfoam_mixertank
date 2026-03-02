#!/bin/bash
#------------------------------------------------------------------------------
# build_push.sh: Docker イメージをローカルでビルドし Artifact Registry へ Push
#
# 使い方:
#   source gcp/.env && bash gcp/build_push.sh
#
# 前提条件:
#   - Docker Desktop または Docker Engine がインストール済み
#   - gcloud auth configure-docker ${REGION}-docker.pkg.dev 実行済み
#   - 環境変数 PROJECT_ID, REGION, AR_REPO, IMAGE_NAME, IMAGE_TAG が設定済み
#------------------------------------------------------------------------------
set -euo pipefail

# 環境変数チェック
: "${PROJECT_ID:?環境変数 PROJECT_ID が設定されていません}"
: "${REGION:?環境変数 REGION が設定されていません}"
: "${AR_REPO:?環境変数 AR_REPO が設定されていません}"
: "${IMAGE_NAME:?環境変数 IMAGE_NAME が設定されていません}"
: "${IMAGE_TAG:=${IMAGE_TAG:-latest}}"

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# スクリプトのある gcp/ から test/ ルートへ移動
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "========================================"
echo "  Docker ビルド & Push"
echo "  イメージ: ${IMAGE_URI}"
echo "========================================"

# --- Artifact Registry リポジトリの作成（存在しない場合のみ） ---
echo ""
echo "[1/4] Artifact Registry リポジトリを確認・作成"
if ! gcloud artifacts repositories describe "${AR_REPO}" \
        --location="${REGION}" --project="${PROJECT_ID}" > /dev/null 2>&1; then
    gcloud artifacts repositories create "${AR_REPO}" \
        --repository-format=docker \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --description="OpenFOAM simulation containers"
    echo "  リポジトリ作成: ${AR_REPO}"
else
    echo "  リポジトリ既存: ${AR_REPO}"
fi

# --- Docker 認証設定 ---
echo ""
echo "[2/4] Docker 認証設定 (gcloud auth configure-docker)"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# --- ローカルで Docker ビルド ---
echo ""
echo "[3/4] Docker ビルド (context: ${REPO_ROOT}/docker/)"
docker build \
    --platform linux/amd64 \
    -t "${IMAGE_URI}" \
    "${REPO_ROOT}/docker/"

echo "  ビルド完了: ${IMAGE_URI}"

# --- Artifact Registry へ Push ---
echo ""
echo "[4/4] Artifact Registry へ Push"
docker push "${IMAGE_URI}"

echo ""
echo "========================================"
echo "  完了"
echo "  イメージ URI: ${IMAGE_URI}"
echo "========================================"
