#!/bin/bash
echo "Running unit tests in an isolated container..."
docker run --rm \
    -v "$PWD:/app" \
    -w /app \
    python:3.9-slim \
    bash -c "pip install -q pytest moto boto3 && PYTHONPATH=/app pytest -v -W ignore::DeprecationWarning"