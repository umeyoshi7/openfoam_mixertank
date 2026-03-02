#!/usr/bin/env python3
"""
submit_job.py: Vertex AI Custom Job で OpenFOAM フルワークフローを実行するスクリプト

フルワークフロー (コンテナ内で自動実行):
  MRF simpleFoam (定常) → mapFields → pimpleFoam (非定常) → 結果を GCS へ保存

使い方:
    # 環境変数ファイルを読み込んでから実行
    source gcp/.env

    # ジョブ投入 (非同期)
    python gcp/submit_job.py \\
        --project ${PROJECT_ID} \\
        --region  ${REGION} \\
        --bucket  ${BUCKET} \\
        --image   ${IMAGE_URI} \\
        --ncores  ${NCORES} \\
        --machine-type ${MACHINE_TYPE}

    # ジョブ投入 (完了まで待機)
    python gcp/submit_job.py \\
        --project ${PROJECT_ID} \\
        --region  ${REGION} \\
        --bucket  ${BUCKET} \\
        --image   ${IMAGE_URI} \\
        --ncores  ${NCORES} \\
        --sync

前提条件:
    pip install -r gcp/requirements.txt
    gcloud auth application-default login
    Docker イメージが Artifact Registry にプッシュ済み (bash gcp/build_push.sh)
    ケースファイルが GCS にアップロード済み (bash gcp/upload_case.sh)
"""

import argparse
import sys
from datetime import datetime

import google.cloud.aiplatform as aiplatform


def submit_openfoam_job(
    project_id: str,
    region: str,
    gcs_bucket: str,
    image_uri: str,
    ncores: int = 4,
    machine_type: str = "n1-standard-4",
    timeout_hours: int = 24,
    result_prefix: str = "results",
    mrf_end_time: int = 3000,
    sync: bool = False,
) -> None:
    """
    Vertex AI Custom Job を作成して実行する。

    Args:
        project_id:    GCP プロジェクト ID
        region:        Vertex AI リージョン
        gcs_bucket:    ケースと結果を保存する GCS バケット名
        image_uri:     Artifact Registry のコンテナイメージ URI
        ncores:        MPI コア数
        machine_type:  Compute Engine マシンタイプ (例: n1-standard-4)
        timeout_hours: タイムアウト [時間]
        result_prefix: GCS 上の結果プレフィックス
        mrf_end_time:  MRF 定常計算の終了イテレーション数
        sync:          True の場合はジョブ完了を待機する
    """
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    display_name = f"openfoam-ami-{timestamp}"

    print("======================================")
    print("  OpenFOAM Vertex AI Custom Job 投入")
    print(f"  プロジェクト    : {project_id}")
    print(f"  リージョン      : {region}")
    print(f"  イメージ        : {image_uri}")
    print(f"  GCS バケット    : gs://{gcs_bucket}")
    print(f"  コア数          : {ncores}")
    print(f"  マシンタイプ    : {machine_type}")
    print(f"  MRF endTime     : {mrf_end_time}")
    print(f"  タイムアウト    : {timeout_hours}h")
    print(f"  ジョブ名        : {display_name}")
    print("======================================")

    aiplatform.init(project=project_id, location=region)

    job = aiplatform.CustomJob(
        display_name=display_name,
        worker_pool_specs=[{
            "machine_spec": {
                "machine_type": machine_type,
            },
            "replica_count": 1,
            "container_spec": {
                "image_uri": image_uri,
                "env": [
                    {"name": "GCS_BUCKET",        "value": gcs_bucket},
                    {"name": "NCORES",            "value": str(ncores)},
                    {"name": "GCS_RESULT_PREFIX", "value": result_prefix},
                    {"name": "MRF_END_TIME",      "value": str(mrf_end_time)},
                ],
            },
        }],
        staging_bucket=f"gs://{gcs_bucket}/staging",
    )

    timeout_seconds = timeout_hours * 3600

    print(f"\nジョブを投入中...")
    job.run(
        sync=sync,
        timeout=timeout_seconds,
    )

    if sync:
        print(f"\n  ジョブ完了: {job.display_name}")
        print(f"  状態: {job.state}")
    else:
        print(f"\n  ジョブを非同期投入しました。")
        print(f"\n  進捗確認:")
        print(f"    gcloud ai custom-jobs list \\")
        print(f"        --region={region} --project={project_id}")
        print(f"\n  コンソール:")
        print(f"    https://console.cloud.google.com/vertex-ai/training/custom-jobs?project={project_id}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Vertex AI Custom Job で OpenFOAM フルワークフローを投入",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--project",      required=True, help="GCP プロジェクト ID")
    parser.add_argument("--region",       required=True, help="Vertex AI リージョン (例: asia-northeast1)")
    parser.add_argument("--bucket",       required=True, help="GCS バケット名")
    parser.add_argument("--image",        required=True, help="コンテナイメージ URI (Artifact Registry)")
    parser.add_argument("--ncores",       type=int, default=4,              help="MPI コア数")
    parser.add_argument("--machine-type", default="n1-standard-4",          help="Compute Engine マシンタイプ")
    parser.add_argument("--timeout-hours",type=int, default=24,             help="タイムアウト [時間]")
    parser.add_argument("--result-prefix",default="results",                help="GCS 結果プレフィックス")
    parser.add_argument("--mrf-end-time", type=int, default=3000,           help="MRF endTime (イテレーション数)")
    parser.add_argument("--sync",         action="store_true",
                        help="ジョブ完了まで待機する (デフォルト: 非同期)")

    args = parser.parse_args()

    try:
        submit_openfoam_job(
            project_id=args.project,
            region=args.region,
            gcs_bucket=args.bucket,
            image_uri=args.image,
            ncores=args.ncores,
            machine_type=args.machine_type,
            timeout_hours=args.timeout_hours,
            result_prefix=args.result_prefix,
            mrf_end_time=args.mrf_end_time,
            sync=args.sync,
        )
    except Exception as e:
        print(f"\nエラー: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
