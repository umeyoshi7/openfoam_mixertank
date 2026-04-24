#!/bin/bash
#------------------------------------------------------------------------------
# deploy.sh: Docker イメージをビルドして Artifact Registry にプッシュ、
#           Vertex AI Custom Job を投入するデプロイスクリプト
#
# 前提:
#   - Docker Engine インストール済み (sudo apt-get install docker.io)
#   - gcloud CLI インストール済み (~/google-cloud-sdk/bin/gcloud または PATH 上)
#   - gcloud auth login 実行済み (対話的)
#   - Artifact Registry に openfoam リポジトリ作成済み (初回のみ)
#
# 使い方:
#   ./deploy.sh build-push        # イメージをビルドして Artifact Registry へプッシュ
#   ./deploy.sh submit-mesh       # メッシュ生成ジョブを投入
#   ./deploy.sh submit-solver     # ソルバージョブを投入
#   ./deploy.sh setup-registry    # 初回: Artifact Registry リポジトリを作成
#   ./deploy.sh upload-cases      # ケースファイルを GCS にアップロード
#   ./deploy.sh all               # cases upload → build-push → submit-mesh → submit-solver
#
# 環境変数（必須、~/.openfoam_env で読み込み可能）:
#   PROJECT_ID        GCP プロジェクト ID
#   GCS_BUCKET        GCS バケット名
#   REGION            リージョン (デフォルト: asia-northeast1)
#   AR_REPO           Artifact Registry リポジトリ名 (デフォルト: openfoam)
#------------------------------------------------------------------------------
set -euo pipefail

# 設定ファイル読み込み
[ -f "${HOME}/.openfoam_env" ] && source "${HOME}/.openfoam_env"

PROJECT_ID="${PROJECT_ID:?ERROR: PROJECT_ID を設定してください (~/.openfoam_env または環境変数)}"
GCS_BUCKET="${GCS_BUCKET:?ERROR: GCS_BUCKET を設定してください}"
REGION="${REGION:-asia-northeast1}"
AR_REPO="${AR_REPO:-openfoam}"

# gcloud 検出: PATH 優先、なければ ~/google-cloud-sdk/bin/
GCLOUD="${GCLOUD:-$(command -v gcloud 2>/dev/null || echo ${HOME}/google-cloud-sdk/bin/gcloud)}"
[ -x "${GCLOUD}" ] || { echo "ERROR: gcloud が見つかりません: ${GCLOUD}"; exit 1; }

GSUTIL="${GSUTIL:-$(command -v gsutil 2>/dev/null || echo ${HOME}/google-cloud-sdk/bin/gsutil)}"

# イメージ URI
MESH_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/openfoam-mesh:latest"
SOLVER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/openfoam-solver:latest"

# スクリプト配置ディレクトリ（リポジトリルート）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_DIR="${SCRIPT_DIR}/docker"
VERTEX_DIR="${SCRIPT_DIR}/vertex_ai"

CMD="${1:-help}"

case "${CMD}" in

# ---------------------------------------------------------------------------
setup-registry)
    echo "=== Artifact Registry リポジトリ作成 ==="
    echo "PROJECT: ${PROJECT_ID}"
    echo "REGION:  ${REGION}"
    echo "REPO:    ${AR_REPO}"
    "${GCLOUD}" artifacts repositories create "${AR_REPO}" \
        --repository-format=docker \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --description="OpenFOAM 11 Docker images for Vertex AI" \
        2>&1 || echo "  (既に存在する可能性があります)"
    "${GCLOUD}" auth configure-docker "${REGION}-docker.pkg.dev" --quiet
    echo "Artifact Registry セットアップ完了"
    ;;

# ---------------------------------------------------------------------------
upload-cases)
    echo "=== ケースファイルを GCS にアップロード ==="
    echo "宛先: gs://${GCS_BUCKET}/cases/"
    # 結果ディレクトリや生成物を除外してアップロード
    "${GSUTIL}" -m rsync -r -x '^([0-9]+(\.[0-9]+)?|processor[0-9]+|constant/polyMesh|constant/fvMesh|log\..*)$' \
        "${SCRIPT_DIR}/LKHD045" \
        "gs://${GCS_BUCKET}/cases/LKHD045"
    "${GSUTIL}" -m rsync -r -x '^([0-9]+(\.[0-9]+)?|processor[0-9]+|constant/polyMesh|constant/fvMesh|log\..*)$' \
        "${SCRIPT_DIR}/LKHD045MRF" \
        "gs://${GCS_BUCKET}/cases/LKHD045MRF"
    echo "  アップロード完了"
    ;;

# ---------------------------------------------------------------------------
build-push)
    echo "=== Docker イメージのビルドとプッシュ ==="
    # Docker 認証（毎回実行しても問題なし）
    "${GCLOUD}" auth configure-docker "${REGION}-docker.pkg.dev" --quiet

    echo ""
    echo "--- mesh イメージ ---"
    docker build -f "${DOCKER_DIR}/Dockerfile.mesh" -t "${MESH_IMAGE}" "${DOCKER_DIR}/"
    docker push "${MESH_IMAGE}"
    echo "  push 完了: ${MESH_IMAGE}"

    echo ""
    echo "--- solver イメージ ---"
    docker build -f "${DOCKER_DIR}/Dockerfile.solver" -t "${SOLVER_IMAGE}" "${DOCKER_DIR}/"
    docker push "${SOLVER_IMAGE}"
    echo "  push 完了: ${SOLVER_IMAGE}"
    ;;

# ---------------------------------------------------------------------------
submit-mesh)
    echo "=== メッシュ生成ジョブを Vertex AI に投入 ==="
    TMP_YAML=$(mktemp --suffix=.yaml)
    sed -e "s|<PROJECT_ID>|${PROJECT_ID}|g" \
        -e "s|your-openfoam-bucket|${GCS_BUCKET}|g" \
        "${VERTEX_DIR}/job_mesh.yaml" > "${TMP_YAML}"
    echo "--- 送信する YAML ---"
    cat "${TMP_YAML}"
    echo ""
    "${GCLOUD}" ai custom-jobs create \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --config="${TMP_YAML}" \
        --display-name="openfoam-mesh-$(date +%Y%m%d-%H%M%S)"
    rm -f "${TMP_YAML}"
    ;;

# ---------------------------------------------------------------------------
submit-solver)
    echo "=== ソルバージョブを Vertex AI に投入 ==="
    TMP_YAML=$(mktemp --suffix=.yaml)
    sed -e "s|<PROJECT_ID>|${PROJECT_ID}|g" \
        -e "s|your-openfoam-bucket|${GCS_BUCKET}|g" \
        "${VERTEX_DIR}/job_solver.yaml" > "${TMP_YAML}"
    echo "--- 送信する YAML ---"
    cat "${TMP_YAML}"
    echo ""
    "${GCLOUD}" ai custom-jobs create \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --config="${TMP_YAML}" \
        --display-name="openfoam-solver-$(date +%Y%m%d-%H%M%S)"
    rm -f "${TMP_YAML}"
    ;;

# ---------------------------------------------------------------------------
list-jobs)
    "${GCLOUD}" ai custom-jobs list \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --sort-by=~createTime \
        --limit=10
    ;;

# ---------------------------------------------------------------------------
all)
    "${0}" setup-registry
    "${0}" upload-cases
    "${0}" build-push
    "${0}" submit-mesh
    echo ""
    echo "メッシュジョブを投入しました。完了後、以下を実行:"
    echo "  ${0} submit-solver"
    ;;

# ---------------------------------------------------------------------------
help|*)
    cat << USAGE
使い方:
  ${0} setup-registry   初回のみ: Artifact Registry リポジトリ作成 + Docker 認証
  ${0} upload-cases     ケースファイル (LKHD045, LKHD045MRF) を GCS にアップロード
  ${0} build-push       Docker イメージ (mesh + solver) をビルドして Artifact Registry にプッシュ
  ${0} submit-mesh      メッシュ生成ジョブを Vertex AI に投入
  ${0} submit-solver    ソルバージョブを Vertex AI に投入
  ${0} list-jobs        最新の 10 ジョブを表示
  ${0} all              setup → upload → build-push → submit-mesh（solver は手動）

必須環境変数 (~/.openfoam_env に書くと便利):
  PROJECT_ID=your-gcp-project
  GCS_BUCKET=your-openfoam-bucket
  REGION=asia-northeast1   # デフォルト
  AR_REPO=openfoam         # デフォルト

現在の設定:
  PROJECT_ID=${PROJECT_ID}
  GCS_BUCKET=${GCS_BUCKET}
  REGION=${REGION}
  AR_REPO=${AR_REPO}
  GCLOUD=${GCLOUD}
USAGE
    ;;

esac
