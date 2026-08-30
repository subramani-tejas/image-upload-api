import json
import os
import uuid
import boto3
from botocore.config import Config

s3_client = boto3.client(
    's3',
    endpoint_url=os.environ.get('EXTERNAL_ENDPOINT_URL', 'http://localhost:4566'),
    region_name='us-east-1',
    config=Config(signature_version='s3v4')
)
BUCKET_NAME = os.environ.get('BUCKET_NAME', 'user-images-local')

def lambda_handler(event, context):    
    try:
        body = json.loads(event.get('body', '{}'))
        user_id = event.get('pathParameters', {}).get('user_id')
        
        if not user_id or not body.get('filename'):
            # TODO: refactor into separate _build_response()
            return {
                "statusCode": 400, 
                "body": json.dumps({"error": "Missing user_id or filename"})
            }

        image_id = str(uuid.uuid4())
        s3_key = f"users/{user_id}/images/{image_id}-{body['filename']}"
        
        metadata = {
            'title': body.get('title', 'Untitled'),
            'tags': json.dumps(body.get('tags', []))
        }

        presigned_url = s3_client.generate_presigned_url(
            ClientMethod='put_object',
            Params={
                'Bucket': BUCKET_NAME,
                'Key': s3_key,
                'ContentType': body.get('content_type', 'image/jpeg'),
                'Metadata': metadata
            },
            ExpiresIn=300
        )

        return {
            "statusCode": 200,
            "body": json.dumps({
                "image_id": image_id,
                "upload_url": presigned_url,
                "expires_in_seconds": 300,
                "required_headers": {
                    "Content-Type": body.get('content_type', 'image/jpeg'),
                    "x-amz-meta-title": metadata['title'],
                    "x-amz-meta-tags": metadata['tags']
                }
            })
        }
    except Exception as e:
        # TODO: refactor into logging framework
        print(f"Error generating pre-signed URL: {str(e)}")
        return {
            "statusCode": 500, 
            "body": json.dumps({
                "error": "Internal error in generating pre-signed URL"
            })
        }