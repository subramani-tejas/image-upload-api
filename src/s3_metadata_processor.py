import json
import os
import urllib.parse
import boto3

localstack_host = os.environ.get('LOCALSTACK_HOSTNAME', 'localhost')
endpoint_url = f"http://{localstack_host}:4566"
region = 'us-east-1'

s3_client = boto3.client('s3', endpoint_url=endpoint_url, region_name=region)
dynamodb = boto3.resource('dynamodb', endpoint_url=endpoint_url, region_name=region)
table = dynamodb.Table(os.environ.get('TABLE_NAME', 'ImageMetadata'))

def lambda_handler(event, context):    
    for record in event.get('Records', []):
        try:
            bucket = record['s3']['bucket']['name']
            key = urllib.parse.unquote_plus(record['s3']['object']['key'])
            size = record['s3']['object']['size']

            path_parts = key.split('/')
            user_id = path_parts[1]
            file_part = path_parts[-1]
            image_id = file_part.split('-', 1)[0]

            response = s3_client.head_object(Bucket=bucket, Key=key)
            metadata = response.get('Metadata', {})

            title = metadata.get('title', 'Untitled')
            try:
                tags = json.loads(metadata.get('tags', '[]'))
            except json.JSONDecodeError:
                tags = []

            upload_date = response['LastModified'].isoformat()

            item = {
                'PK': f"USER#{user_id}",
                'SK': f"IMAGE#{upload_date}",
                'image_id': image_id,
                's3_key': key,
                'title': title,
                'tags': tags,
                'file_size_bytes': size
            }

            table.put_item(Item=item)
            print(f"Successfully processed and stored metadata for {key}")

        except Exception as e:
            print(f"Error processing record: {str(e)}")
            raise e

    return {"statusCode": 200, "body": "Success"}