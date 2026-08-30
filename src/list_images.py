import json
import os
import boto3
from boto3.dynamodb.conditions import Key, Attr

localstack_host = os.environ.get('LOCALSTACK_HOSTNAME', 'localhost')
dynamodb = boto3.resource(
    'dynamodb', 
    endpoint_url=f"http://{localstack_host}:4566",
    region_name='us-east-1'
)
table = dynamodb.Table(os.environ.get('TABLE_NAME', 'ImageMetadata'))

def lambda_handler(event, context):
    try:
        user_id = event.get('pathParameters', {}).get('user_id')
        if not user_id:
            return {"statusCode": 400, "body": json.dumps({"error": "user_id is required"})}

        query_params = event.get('queryStringParameters') or {}
        
        pk_condition = Key('PK').eq(f"USER#{user_id}")
        
        start_date = query_params.get('start_date')
        end_date = query_params.get('end_date')
        
        if start_date and end_date:
            sk_condition = Key('SK').between(f"IMAGE#{start_date}", f"IMAGE#{end_date}")
        elif start_date:
            sk_condition = Key('SK').between(f"IMAGE#{start_date}", "IMAGE#9999-12-31")
        else:
            sk_condition = Key('SK').begins_with("IMAGE#")
            
        key_expression = pk_condition & sk_condition

        filter_expression = None
        title_search = query_params.get('title')
        tag_search = query_params.get('tag')

        if title_search:
            filter_expression = Attr('title').contains(title_search)
        
        if tag_search:
            tag_condition = Attr('tags').contains(tag_search)
            filter_expression = filter_expression & tag_condition if filter_expression else tag_condition

        limit = int(query_params.get('limit', 50))
        next_token = query_params.get('next_token')

        query_kwargs = {
            'KeyConditionExpression': key_expression,
            'Limit': limit
        }
        if filter_expression:
            query_kwargs['FilterExpression'] = filter_expression
        if next_token:
            query_kwargs['ExclusiveStartKey'] = json.loads(next_token)

        response = table.query(**query_kwargs)

        items = [{
            'image_id': item.get('image_id'),
            'title': item.get('title'),
            'tags': item.get('tags'),
            'upload_date': item.get('SK').split('#')[1],
            'file_size_bytes': int(item.get('file_size_bytes', 0))
        } for item in response.get('Items', [])]

        result = {
            "items": items,
            "count": response.get('Count', 0)
        }
        
        if 'LastEvaluatedKey' in response:
            result['next_token'] = json.dumps(response['LastEvaluatedKey'])

        return {"statusCode": 200, "body": json.dumps(result)}

    except Exception as e:
        print(f"Error querying images: {str(e)}")
        return {"statusCode": 500, "body": json.dumps({"error": "Internal server error"})}