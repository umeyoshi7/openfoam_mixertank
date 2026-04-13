# ==============================================================================
# OpenFOAM v11 (openfoam.org) + Google Cloud CLI
# ==============================================================================
# openfoam.org 公式 Docker イメージ。
# OpenFOAM v11 が /opt/openfoam11/ にインストール済み。
# ParaView 5.10 が含まれるが、本ジョブではソルバー実行のみに使用。
FROM openfoam/openfoam11-paraview510

# イメージのメタデータ（docker inspect で確認可能）
LABEL description="OpenFOAM v11 stirred tank simulation with GCS integration"

# ------------------------------------------------------------------------------
# Google Cloud CLI のインストール
# ------------------------------------------------------------------------------
# entrypoint.sh が gsutil を使い GCS からケースをダウンロード・
# 結果をアップロードするため google-cloud-cli が必要。
# apt リポジトリを GPG 署名付きで追加してからインストールする。
#
# インストールするパッケージ:
#   curl             : GPG 公開鍵を HTTPS でフェッチするために使用
#   gnupg            : GPG 公開鍵の検証・変換 (gpg --dearmor) に使用
#   ca-certificates  : HTTPS 通信の TLS 証明書検証に必要
#   lsb-release      : OS コードネーム取得（apt リポジトリ URL 生成に使用）
#   apt-transport-https : HTTPS 経由の apt リポジトリを利用するために必要
#   google-cloud-cli : gsutil を含む Google Cloud コマンドラインツール群
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        gnupg \
        ca-certificates \
        lsb-release \
        apt-transport-https \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
        https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*
# 最後に apt キャッシュを削除してイメージサイズを削減する

# ------------------------------------------------------------------------------
# 作業ディレクトリの設定
# ------------------------------------------------------------------------------
# /workspace を作業ディレクトリに設定する（存在しない場合は自動作成）。
# entrypoint.sh が GCS からケースファイルをここにダウンロードし、
# 以降の全 OpenFOAM コマンドはこのディレクトリ以下で動作する。
WORKDIR /workspace

# ------------------------------------------------------------------------------
# エントリポイントスクリプトの配置
# ------------------------------------------------------------------------------
# フルワークフロースクリプトをコンテナの / にコピーする。
# WORKDIR (/workspace) ではなく / に置くことで、
# 以降の cd コマンドによる作業ディレクトリ変更の影響を受けない。
COPY entrypoint.sh /entrypoint.sh

# Vertex AI はコンテナの ENTRYPOINT を直接実行するため実行権限の付与が必須
RUN chmod +x /entrypoint.sh

# ------------------------------------------------------------------------------
# コンテナ起動コマンドの指定
# ------------------------------------------------------------------------------
# JSON 配列形式（exec 形式）で記述する。
# shell 形式 (ENTRYPOINT "/entrypoint.sh") と異なり、
# exec 形式ではシグナル (SIGTERM 等) がシェル経由でなく
# スクリプトプロセスに直接届くため、Vertex AI のジョブ停止が確実に機能する。
ENTRYPOINT ["/entrypoint.sh"]
