import json
import os
import boto3
from botocore.client import Config
from boto3.dynamodb.conditions import Key, Attr

localstack_host = os.environ.get('LOCALSTACK_HOSTNAME', 'localhost')
dynamodb = boto3.resource(
    'dynamodb', 
    endpoint_url=f"http://{localstack_host}:4566",
    region_name='us-east-1'
)

s3_client = boto3.client(
    's3',
    endpoint_url=os.environ.get('EXTERNAL_ENDPOINT_URL', 'http://localhost:4566'),
    region_name='us-east-1',
    config=Config(signature_version='s3v4')
)

table = dynamodb.Table(os.environ.get('TABLE_NAME', 'ImageMetadata'))
BUCKET_NAME = os.environ.get('BUCKET_NAME', 'user-images-local')

def lambda_handler(event, context):
    try:
        path_params = event.get('pathParameters', {})
        user_id = path_params.get('user_id')
        image_id = path_params.get('image_id')
        
        if not user_id or not image_id:
            return {"statusCode": 400, "body": json.dumps({"error": "Missing user_id or image_id"})}
        
        response = table.query(
            KeyConditionExpression=Key('PK').eq(f"USER#{user_id}"),
            FilterExpression=Attr('image_id').eq(image_id)
        )
        
        items = response.get('Items', [])
        if not items:
            return {"statusCode": 404, "body": json.dumps({"error": "Image not found"})}
            
        s3_key = items[0]['s3_key']

        presigned_url = s3_client.generate_presigned_url(
            ClientMethod='get_object',
            Params={
                'Bucket': BUCKET_NAME,
                'Key': s3_key
            },
            ExpiresIn=3600
        )

        return {
            "statusCode": 200,
            "body": json.dumps({
                "image_id": image_id,
                "download_url": presigned_url,
                "expires_in_seconds": 3600
            })
        }

    except Exception as e:
        print(f"Error generating view URL: {str(e)}")
        return {"statusCode": 500, "body": json.dumps({"error": "Internal server error"})}