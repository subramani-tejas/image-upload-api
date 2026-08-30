import os
import json
import pytest
import boto3
from moto import mock_aws
from unittest.mock import patch

os.environ['AWS_ACCESS_KEY_ID'] = 'testing'
os.environ['AWS_SECRET_ACCESS_KEY'] = 'testing'
os.environ['AWS_DEFAULT_REGION'] = 'us-east-1'
os.environ['TABLE_NAME'] = 'ImageMetadata'
os.environ['BUCKET_NAME'] = 'test-bucket'

@pytest.fixture
def mock_infrastructure():
    with mock_aws():
        dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
        table = dynamodb.create_table(
            TableName=os.environ['TABLE_NAME'],
            KeySchema=[
                {'AttributeName': 'PK', 'KeyType': 'HASH'},
                {'AttributeName': 'SK', 'KeyType': 'RANGE'}
            ],
            AttributeDefinitions=[
                {'AttributeName': 'PK', 'AttributeType': 'S'},
                {'AttributeName': 'SK', 'AttributeType': 'S'}
            ],
            BillingMode='PAY_PER_REQUEST'
        )
        
        s3 = boto3.client('s3', region_name='us-east-1')
        s3.create_bucket(Bucket=os.environ['BUCKET_NAME'])
        
        yield dynamodb, table, s3

@pytest.fixture
def populated_infrastructure(mock_infrastructure):
    dynamodb, table, s3 = mock_infrastructure
    
    s3_key = "users/usr_123/images/test_image_1.jpg"
    s3.put_object(Bucket=os.environ['BUCKET_NAME'], Key=s3_key, Body=b"fake-image-bytes")
    
    table.put_item(Item={
        'PK': 'USER#usr_123',
        'SK': 'IMAGE#2026-10-31T12:00:00Z',
        'image_id': 'img888',
        's3_key': s3_key,
        'title': 'Beautiful Sunset',
        'tags': ['nature', 'sunset'],
        'file_size_bytes': 1024
    })
    
    yield dynamodb, table, s3

@pytest.fixture
def list_module(mock_infrastructure):
    _, table, _ = mock_infrastructure
    import src.list_images as app
    with patch.object(app, 'table', table):
        yield app

@pytest.fixture
def delete_module(populated_infrastructure):
    _, table, s3_client = populated_infrastructure
    import src.delete_image as app
    with patch.object(app, 'table', table), patch.object(app, 's3_client', s3_client):
        yield app

def test_list_images_success(list_module, populated_infrastructure):
    event = {
        "pathParameters": {"user_id": "usr_123"},
        "queryStringParameters": {"tag": "nature"}
    }
    
    response = list_module.lambda_handler(event, None)
    
    assert response['statusCode'] == 200
    body = json.loads(response['body'])
    
    assert body['count'] == 1
    assert body['items'][0]['image_id'] == 'img888'
    assert 'nature' in body['items'][0]['tags']

def test_delete_image_success(delete_module, populated_infrastructure):
    _, table, s3 = populated_infrastructure
    s3_key = "users/usr_123/images/img888-sunset.jpg"
    
    event = {
        "pathParameters": {
            "user_id": "usr_123",
            "image_id": "img888"
        }
    }
    
    assert 'Item' in table.get_item(Key={'PK': 'USER#usr_123', 'SK': 'IMAGE#2026-10-31T12:00:00Z'})
    s3.head_object(Bucket=os.environ['BUCKET_NAME'], Key=s3_key) # Raises error if missing
    
    response = delete_module.lambda_handler(event, None)
    
    assert response['statusCode'] == 200
    
    assert 'Item' not in table.get_item(Key={'PK': 'USER#usr_123', 'SK': 'IMAGE#2026-10-31T12:00:00Z'})

    with pytest.raises(Exception) as excinfo:
        s3.head_object(Bucket=os.environ['BUCKET_NAME'], Key=s3_key)
    assert '404' in str(excinfo.value)

@pytest.fixture
def view_module(populated_infrastructure):
    _, table, s3_client = populated_infrastructure
    import src.view_image as app
    with patch.object(app, 'table', table), patch.object(app, 's3_client', s3_client):
        yield app

@pytest.fixture
def processor_module(mock_infrastructure):
    _, table, s3_client = mock_infrastructure
    import src.s3_metadata_processor as app
    with patch.object(app, 'table', table), patch.object(app, 's3_client', s3_client):
        yield app

def test_view_image_success(view_module, populated_infrastructure):
    event = {
        "pathParameters": {
            "user_id": "usr_123",
            "image_id": "img888"
        }
    }
    
    response = view_module.lambda_handler(event, None)
    
    assert response['statusCode'] == 200
    body = json.loads(response['body'])
    assert body['image_id'] == 'img888'
    assert 'download_url' in body
    assert body['expires_in_seconds'] == 3600

def test_s3_metadata_processor_success(processor_module, mock_infrastructure):
    dynamodb, table, s3 = mock_infrastructure
    
    s3_key = "users/usr_456/images/img999-avatar.jpg"
    s3.put_object(
        Bucket=os.environ['BUCKET_NAME'], 
        Key=s3_key, 
        Body=b"fake-bytes",
        Metadata={'title': 'My Avatar', 'tags': '["profile", "face"]'}
    )
    
    event = {
        "Records": [{
            "s3": {
                "bucket": {"name": os.environ['BUCKET_NAME']},
                "object": {
                    "key": "users/usr_456/images/img999-avatar.jpg",
                    "size": 1024
                }
            }
        }]
    }
    
    response = processor_module.lambda_handler(event, None)
    assert response['statusCode'] == 200
    
    db_response = table.query(
        KeyConditionExpression=boto3.dynamodb.conditions.Key('PK').eq('USER#usr_456')
    )
    items = db_response.get('Items', [])
    assert len(items) == 1
    assert items[0]['image_id'] == 'img999'
    assert items[0]['title'] == 'My Avatar'
    assert 'profile' in items[0]['tags']