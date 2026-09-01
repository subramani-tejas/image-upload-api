# image-upload-api

A highly scalable, multi-tenant serverless service layer for concurrent image upload metadata processing service built on AWS. Stores assets in Amazon S3 and persists image metadata in DynamoDB via API Gateway and Lambda.

## Table of Contents
* [Architecture](#architecture)
* [Prerequisites](#prerequisites)
* [Setup & Deployment](#setup--deployment)
* [Testing Instructions](#testing-instructions)
* [API Reference](#api-reference)
    * [1. Generate Upload URL](#1-generate-upload-url)
    * [2. List Images](#2-list-images)
    * [3. View / Download Image](#3-view--download-image)
    * [4. Delete Image](#4-delete-image)
* [Architectural Decisions & Tradeoffs](#architectural-decisions--tradeoffs)
    * [1. Pre-signed URL vs. API Proxy](#1-pre-signed-url-vs-api-proxy)
    * [2. DynamoDB Design](#2-dynamodb-design)
    * [3. Filtering Strategy](#3-filtering-strategy)
    * [4. Synchronous Deletion](#4-synchronous-deletion)
* [Security Risks & Local Tradeoffs](#security-risks--local-tradeoffs)
    * [1. Docker Socket Mounting](#1-docker-socket-mounting)
    * [2. Imperative Setup vs. IaC](#2-imperative-setup-vs-iac)
    * [3. LocalStack Versioning](#3-localstack-versioning)
* [Future Enhancements (TODOs)](#future-enhancements-todos)

## Architecture

This service uses a fully decoupled, event-driven serverless architecture:
*   **API Gateway**: REST entry point routing HTTP requests to Lambda functions.
*   **AWS Lambda**: Stateless microservices handling business logic.
*   **Amazon S3**: Object storage for image binaries. Utilizes Pre-signed URLs to offload heavy I/O from the API layer.
*   **Amazon DynamoDB**: NoSQL database for metadata. Uses a single-table design partitioned by user.
*   **Event-Driven Processing**: S3 `ObjectCreated` events trigger an asynchronous Lambda function to extract object metadata and write to DynamoDB, decoupling the user upload path from database writes.

```mermaid
graph TD
    Client([Client Application])
    API[API Gateway]

    Lambda_Upload[Lambda: GenerateUploadUrl]
    Lambda_List[Lambda: ListImages]
    Lambda_View[Lambda: ViewImage]
    Lambda_Delete[Lambda: DeleteImage]
    Lambda_Process[Lambda: S3MetadataProcessor]

    S3[(Amazon S3)]
    DDB[(Amazon DynamoDB)]

    Client -- POST /upload-url --> API
    Client -- GET /images --> API
    Client -- GET /images/{id} --> API
    Client -- DELETE /images/{id} --> API
    
    Client -- "Upload/Download Binary" --> S3

    API --> Lambda_Upload
    API --> Lambda_List
    API --> Lambda_View
    API --> Lambda_Delete

    Lambda_Upload -. "Generate Presigned PUT" .-> S3
    
    S3 -- "s3:ObjectCreated Event" --> Lambda_Process
    Lambda_Process -- "PutItem (Metadata)" --> DDB

    Lambda_List -- "Query (Filters/Pagination)" --> DDB
    
    Lambda_View -- "Query (Get s3_key)" --> DDB
    Lambda_View -. "Generate Presigned GET" .-> S3

    Lambda_Delete -- "DeleteItem" --> DDB
    Lambda_Delete -- "DeleteObject" --> S3
```

## Prerequisites
*   Docker & Docker Compose
*   AWS CLI (configured with dummy credentials for LocalStack)
*   Python 3.9+

## Setup & Deployment

1. Start the LocalStack environment:
   ```bash
   docker-compose up -d
   ```

2. Export the generated API Gateway ID from the script output to test endpoints:
    ```bash
    export API_ID="<your_api_id>"
    export BASE_URL="http://localhost:4566/restapis/$API_ID/local/_user_request_/users"
    ```

## Testing Instructions
The unit test suite runs in an isolated Docker container, ensuring zero local dependencies (like `pytest` or `moto`) are required.

Steps:
**Steps:**
```bash
chmod +x run_tests.sh
./run_tests.sh
```

## API Reference
### 1. Generate Upload URL
Generates a time-bound S3 pre-signed URL to upload an image securely.

` POST /users/<user-id>/images/upload-url `

Request Body:
```json
{
  "filename": string,
  "title": string,
  "tags": string array,
  "content_type": "image/jpeg"
}
```

#### SAMPLE REQUEST [1/2]
Request for the S3 presigned upload URL.
```json
curl -i -X POST "http://localhost:4566/restapis/hesrgxqhat/local/_user_request_/users/usr_9981/images/upload-url" \
  -H "Content-Type: application/json" \
  -d '{
    "filename": "sunset.jpg",
    "content_type": "image/jpeg",
    "title": "Sunset in Bali",
    "tags": [
        "travel",
        "vacation"
    ]
}'
```

#### SAMPLE RESPONSE [1/2]
```json
{
    "image_id": "42503d66-21a6-40d0-833d-ab992ca1e2b8",
    "upload_url": "<UPLOAD_URL>",
    "expires_in_seconds": 300,
    "required_headers": {
        "Content-Type": "image/jpeg",
        "x-amz-meta-title": "Sunset in Bali",
        "x-amz-meta-tags": "[\"travel\", \"vacation\"]"
    }
}
```

#### SAMPLE REQUEST [2/2]
Upload image to the presigned URL.
```json
curl -i -X PUT 'http://localhost:4566/user-images-local/users/usr_9981/images/e64549b9-687d-4bef-934d-76e14af3ebad-sunset.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=LSIAQAAAAAAAFTYTB4XV%2F20260901%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20260901T172926Z&X-Amz-Expires=300&X-Amz-SignedHeaders=content-type%3Bhost%3Bx-amz-meta-tags%3Bx-amz-meta-title&X-Amz-Security-Token=FQoGZXIvYXdzEjCpYmaZhrcQSYvG%2Bb9RHSSYJFIsy6Kc%2FPW%3Dpbt39m8m1FaWphwowxG7KsmZu9xkCBgjdqLXJKt8lK1cg6nrsyJGVpwiyq76p%3DLpPK6EKaPY2fptHuxt5DF%2BPHMIwLrDlIxL1WbQe08yTZAwr81HhGU3Bn3YPJm5w%2F%3D0KCLHSV5o%3DLfleblnVW5E8R%2FC4oGR7jDQ5BFzj%2FeV22qpbQThZ5me8sOOuFkohvf9U%3DjHWqdfwKG0YUjEGladxIEcqxxuikuVz1WYto%2Bn1ZKGofGT79segTcNXnTtQ96xpkCZXbIyniAmxyKHDQugKZCxtMPC3xBqUjKceue9RuBr89cGanHL&X-Amz-Signature=74507fd2499c52dbab93ac5d9f4ecfad523015068692265a888201cd2a9f5311' \
  -H "Content-Type: image/jpeg" \
  -H "x-amz-meta-title: Sunset in Bali" \
  -H 'x-amz-meta-tags: ["travel", "vacation"]' \
  --data-binary @test_image_1.jpg
```

#### SAMPLE RESPONSE [2/2]
```json
HTTP/1.1 200 OK
Server: TwistedWeb/26.4.0
Date: Sun, 30 Aug 2026 10:01:32 GMT
```
---

### 2. List Images
Retrieves user images with optional filtering and pagination.

` GET /users/{user_id}/images `

Query Parameters:
* `start_date / end_date`: Filter by upload time (Format: YYYY-MM-DD).
* `title`: Substring match on image title.
* `tag`: Exact match on a specific tag.
* `limit`: Number of items per page (default: 50).
* `next_token`: Pagination token.

#### SAMPLE REQUEST
```json
curl -i -X GET "http://localhost:4566/restapis/hesrgxqhat/local/_user_request_/users/usr_9981/images" \
  -H "Content-Type: application/json"
```

#### SAMPLE RESPONSE
```json
{
    "items": [
        {
            "image_id": "f851b65a",
            "title": "Sunset in Bali",
            "tags": [
                "travel",
                "vacation"
            ],
            "upload_date": "2026-08-30T08:58:16+00:00",
            "file_size_bytes": 17
        }
    ],
    "count": 1
}
```

---

### 3. View / Download Image
Generates a pre-signed GET URL for direct, secure S3 download.

` GET /users/{user_id}/images/{image_id} `

#### SAMPLE REQUEST
```json
curl -i -X GET "http://localhost:4566/restapis/hesrgxqhat/local/_user_request_/users/usr_9981/images/e64549b9"
```

#### SAMPLE RESPONSE
```json
{
    "image_id": "a44c865a",
    "download_url": "http://localhost:4566/user-images-local/users/usr_9981/images/a44c865a-2c22-4421-a688-4715f591f604-sunset.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=LSIAQAAAAAAAIYKKFDIM%2F20260830%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20260830T093557Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Security-Token=FQoGZXIvYXdzEYsf3RYiVB1DcSiZyKK0SNqYLALRMJ6IyFtbPvTvMMGH6aljS3DZLLKMMA1I7SE%2FQL4j%2F%3DWOXKnVTSeUjo9rHF9ZuRpwDaiYHnhmeLTbgxi2XhQniYDlobe%3D0NmbbnQLZ0qb0YTaNM1EWJj23MdIBeavmi8CxfkfjN4qe7ig2Ake7xN%3DB1I1322qOgGDk%2Fu1rJg7%2Fd%2BhOZTvWHI9jawfHrgVL%2BM0EiEoCs0hqOJjDY1Gp%3DURhWHU9o1sTBeMFKcHt8z63GkqT8hz%2BOrqkLBSIY%2F688wWZxIo%2FkpDZkD2ESAz2QQkLuqQzb9QTddAsWhQWnG%2FEvZQ9corwrRkQ9jMCi90&X-Amz-Signature=5b70252d1d0a965e7813b0d80772ee220ef8323e8b0fc574632bbe1c768b0b90",
    "expires_in_seconds": 3600
}
```

---

### 4. Delete Image
Permanently removes the image binary and its associated metadata.

` DELETE /users/{user_id}/images/{image_id} `

#### SAMPLE REQUEST
```json
curl -i -X DELETE "http://localhost:4566/restapis/hesrgxqhat/local/_user_request_/users/usr_9981/images/e64549b9"
```

#### SAMPLE RESPONSE
```json
{
    "message": "Image 7bf695fd successfully deleted",
    "image_id": "7bf695fd"
}
```

## Architectural Decisions & Tradeoffs
### 1. Pre-signed URL vs. API Proxy
**Decision**: The API does not accept or return binary data directly. Instead, it generates S3 Pre-signed URLs providing cloud native scalability.

**Tradeoff**: This prevents hitting API Gateway (10MB) and Lambda (6MB) payload limits, reducing compute cost and latency. API Gateway encodes traffic to base64 which bloats payload by ~33%. The client must make two network calls (one to the API, one to S3), but gains scalability.

### 2. DynamoDB Design
**Decision**: The table uses USER#{user_id} as the Partition Key and IMAGE#{upload_date} as the Sort Key.

**Tradeoff**: This ensures all data for a specific user is collocated on the same physical partition, making list operations incredibly fast.

### 3. Filtering Strategy
**Decision**: Tag and title searches use DynamoDB FilterExpression.

**Tradeoff**: This is cost-effective for typical user partitions, but FilterExpression consumes Read Capacity Units (RCUs) for all data read before the filter is applied. At a large enterprise scale, this data would be streamed to Amazon OpenSearch for complex, multi-attribute indexing.

### 4. Synchronous Deletion

**Decision**: The delete endpoint removes both S3 and DynamoDB data synchronously.

**Tradeoff**: Provides immediate consistency to the client. In a distributed, high throughput production system, this would move to an event-driven soft-delete model (e.g., setting a TTL in DynamoDB, triggering a stream to delete the S3 object).

## Security Risks & Local Tradeoffs

### 1. Docker Socket Mounting
In `docker-compose.yml`, the host Docker socket is mounted (`/var/run/docker.sock:/var/run/docker.sock`). This is required for LocalStack to spin up sibling containers to emulate AWS Lambda execution environments. 

I accept this security tradeoff locally; the convenience of offline Lambda testing outweighs the negligible risk of a local network container escape attack.

### 2. Imperative Setup vs. IaC
For this assignment, infrastructure is provisioned imperatively via a bash script (`setup.sh`) utilizing LocalStack initialization hooks. 

In a production environment, this is brittle and lacks state management. I would replace this with declarative IaC tools like Terraform or CloudFormation.

### 3. LocalStack Versioning
I intentionally pinned an older version (4.4.0) of the LocalStack image for this demo to prioritize Developer Experience (DX). Newer versions frequently introduce strict Auth Token requirements. 

Bypassing this ensures the reviewer can spin up the environment friction-free without needing to configure a LocalStack account.


## Future Enhancements (TODOs)
1. **Observability:** Replace standard ` print() ` statements with structured JSON logging using AWS Lambda Powertools.

2. **DRY Code:** Refactor repetitive HTTP dictionary returns into a centralized ` _build_response() ` utility method.

3. **Idempotency Handling:**

S3's delete_object returns a 200 OK even if the object does not exist. However, if a client double-clicks the delete button, the second request will fail at the initial table.query lookup (returning a 404). Return a consistent 200 OK for idempotent delete retries.

4. **DynamoDB Pagination Flaw:**

Applied Limit in the same query as FilterExpression. In DynamoDB, the limit is applied to the data read before the filter is evaluated. If a user sets a limit of 50, DynamoDB reads 50 items and filters out 49, returning only 1 item to the client along with a next_token. Clients might perceive this as a broken API returning unpredictable page sizes.

5. **Unhandled Type Exceptions:**

Cast the limit parameter directly using `int(query_params.get('limit', 50))`. If a user passes a non-numeric string like `?limit=abc`, Python will throw a ValueError, resulting in a 500 Internal Server Error instead of a 400 Bad Request.

6. **Date Format Assumptions:**

The sort key condition relies on lexicographical sorting for start_date and end_date. Because I do not validate or enforce ISO8601 formatting on the input dates, invalid date strings will result in silent logical errors and return incorrect data sets.

7. **Leaking Database Internals:**
I serialize the raw DynamoDB LastEvaluatedKey directly to JSON and send it to the client as next_token. This couples the client to internal database schema.
