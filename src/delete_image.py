import json
import os
import boto3
from boto3.dynamodb.conditions import Key, Attr

localstack_host = os.environ.get('LOCALSTACK_HOSTNAME', 'localhost')
endpoint_url = f"http://{localstack_host}:4566"
region = 'us-east-1'

dynamodb = boto3.resource('dynamodb', endpoint_url=endpoint_url, region_name=region)
s3_client = boto3.client('s3', endpoint_url=endpoint_url, region_name=region)

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
            
        item = items[0]
        s3_key = item['s3_key']
        sk = item['SK']
        
        s3_client.delete_object(Bucket=BUCKET_NAME, Key=s3_key)
        
        table.delete_item(
            Key={
                'PK': f"USER#{user_id}",
                'SK': sk
            }
        )

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": f"Image {image_id} successfully deleted",
                "image_id": image_id
            })
        }

    except Exception as e:
        print(f"Error deleting image: {str(e)}")
        return {"statusCode": 500, "body": json.dumps({"error": "Internal server error"})}