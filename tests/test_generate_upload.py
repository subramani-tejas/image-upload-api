import os
import json
import pytest
import boto3
from moto import mock_aws
from unittest.mock import patch

os.environ['AWS_ACCESS_KEY_ID'] = 'testing'
os.environ['AWS_SECRET_ACCESS_KEY'] = 'testing'
os.environ['AWS_DEFAULT_REGION'] = 'us-east-1'
os.environ['BUCKET_NAME'] = 'test-bucket'

@pytest.fixture
def mock_s3():    
    with mock_aws():
        s3 = boto3.client('s3', region_name='us-east-1')
        s3.create_bucket(Bucket=os.environ['BUCKET_NAME'])
        yield s3

@pytest.fixture
def lambda_module(mock_s3):
    import src.generate_upload_url as app
    with patch.object(app, 's3_client', mock_s3):
        yield app

def test_generate_upload_url_success(lambda_module):
    event = {
        "pathParameters": {"user_id": "usr_123"},
        "body": json.dumps({
            "filename": "test.png",
            "title": "My Test Image",
            "tags": ["test", "mock"],
            "content_type": "image/png"
        })
    }
    
    response = lambda_module.lambda_handler(event, None)
    
    assert response['statusCode'] == 200
    body = json.loads(response['body'])
    
    assert 'image_id' in body
    assert 'upload_url' in body
    assert body['expires_in_seconds'] == 300
    assert body['required_headers']['x-amz-meta-title'] == "My Test Image"

def test_generate_upload_url_missing_params(lambda_module):
    event = {
        "pathParameters": {"user_id": "usr_123"},
        "body": json.dumps({})  # no filename
    }
    
    response = lambda_module.lambda_handler(event, None)
    
    assert response['statusCode'] == 400
    body = json.loads(response['body'])
    assert "error" in body