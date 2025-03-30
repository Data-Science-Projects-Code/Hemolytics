import os
import boto3
import requests


def lambda_handler(event, context):
    s3_bucket = os.environ["S3_BUCKET"]
    github_repo = os.environ["GITHUB_REPO"]
    github_path = os.environ["GITHUB_PATH"]

    # GitHub API URL
    api_url = f"https://api.github.com/repos/{github_repo}/contents/{github_path.replace('tree/main/', '')}"

    # Make request to GitHub API
    response = requests.get(api_url)
    if response.status_code != 200:
        print(f"Error fetching GitHub data: {response.status_code}, {response.text}")
        return {
            "statusCode": response.status_code,
            "body": f"Failed to fetch data from GitHub: {response.text}",
        }

    s3 = boto3.client("s3")

    files_processed = []
    contents = response.json()

    for item in contents:
        if (
            item["name"].endswith(".sqlite")
            or item["name"].endswith(".sqlite3")
            or item["name"].endswith(".db")
        ):
            print(f"Processing file: {item['name']}")

            if item["type"] == "file":
                download_url = item["download_url"]
                file_response = requests.get(download_url)

                if file_response.status_code == 200:
                    s3_key = f"data/{item['name']}"
                    s3.put_object(
                        Bucket=s3_bucket, Key=s3_key, Body=file_response.content
                    )
                    files_processed.append(item["name"])
                    print(f"Successfully uploaded {item['name']} to S3")
                else:
                    print(
                        f"Failed to download {item['name']}: {file_response.status_code}"
                    )

    return {
        "statusCode": 200,
        "body": f"Successfully processed {len(files_processed)} files: {', '.join(files_processed)}",
    }
