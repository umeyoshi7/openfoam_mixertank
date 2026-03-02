# OpenFOAM v2012 (openfoam.com) + Google Cloud CLI
# ベースイメージ: openfoam.com 公式 (ParaView 5.6 付き)
FROM openfoam/openfoam2012-paraview56:latest

LABEL description="OpenFOAM v2012 stirred tank simulation with GCS integration"

# システムパッケージ + Google Cloud CLI (apt-get 経由)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        gnupg \
        python3 \
        python3-pip \
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

# Python パッケージ (GCS クライアント)
RUN pip3 install --no-cache-dir \
    google-cloud-storage==2.14.0

# 作業ディレクトリ
RUN mkdir -p /workspace
WORKDIR /workspace

# エントリポイントスクリプト
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# コンテナ内は root 実行のため /workspace に全権限付与
RUN chmod -R 777 /workspace

ENTRYPOINT ["/entrypoint.sh"]
