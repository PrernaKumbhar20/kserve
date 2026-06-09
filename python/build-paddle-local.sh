#!/bin/bash

# Build script for PaddlePaddle ppc64le Docker image using local wheel files
# This script builds the Docker image with locally built PaddlePaddle wheels

set -e

echo "=========================================="
echo "PaddlePaddle ppc64le Local Build Script"
echo "=========================================="

# Configuration
WHEEL_SOURCE_DIR="/home/ubuntu/paddle/paddle-wheel"
WHEEL_DEST_DIR="./paddle-wheels"
IMAGE_NAME="kserve/paddleserver"
IMAGE_TAG="ppc64le-local"
DOCKERFILE="paddle-local.Dockerfile"

# Step 1: Create directory for wheels
echo ""
echo "Step 1: Creating paddle-wheels directory..."
mkdir -p "$WHEEL_DEST_DIR"

# Step 2: Copy wheel files from remote location
echo ""
echo "Step 2: Copying PaddlePaddle wheel files..."
echo "Source: $WHEEL_SOURCE_DIR"
echo "Destination: $WHEEL_DEST_DIR"

if [ -f "$WHEEL_SOURCE_DIR/paddlepaddle-3.0.0-cp311-cp311-linux_ppc64le.whl" ]; then
    cp "$WHEEL_SOURCE_DIR/paddlepaddle-3.0.0-cp311-cp311-linux_ppc64le.whl" "$WHEEL_DEST_DIR/"
    echo "✓ Copied Python 3.11 wheel"
else
    echo "⚠ Warning: Python 3.11 wheel not found"
fi

if [ -f "$WHEEL_SOURCE_DIR/paddlepaddle-3.0.0-cp312-cp312-linux_ppc64le.whl" ]; then
    cp "$WHEEL_SOURCE_DIR/paddlepaddle-3.0.0-cp312-cp312-linux_ppc64le.whl" "$WHEEL_DEST_DIR/"
    echo "✓ Copied Python 3.12 wheel"
else
    echo "⚠ Warning: Python 3.12 wheel not found"
fi

# Step 3: Verify wheels are present
echo ""
echo "Step 3: Verifying wheel files..."
ls -lh "$WHEEL_DEST_DIR"/*.whl 2>/dev/null || {
    echo "❌ Error: No wheel files found in $WHEEL_DEST_DIR"
    echo "Please ensure wheel files are copied to $WHEEL_DEST_DIR"
    exit 1
}

# Step 4: Build Docker image
echo ""
echo "Step 4: Building Docker image..."
echo "Image: $IMAGE_NAME:$IMAGE_TAG"
echo "Platform: linux/ppc64le"
echo ""

docker buildx build \
    --platform linux/ppc64le \
    --file "$DOCKERFILE" \
    --tag "$IMAGE_NAME:$IMAGE_TAG" \
    --load \
    .

# Step 5: Verify build
if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✓ Build completed successfully!"
    echo "=========================================="
    echo ""
    echo "Image: $IMAGE_NAME:$IMAGE_TAG"
    echo ""
    echo "To run the container:"
    echo "  docker run --platform linux/ppc64le -p 8080:8080 $IMAGE_NAME:$IMAGE_TAG"
    echo ""
    echo "To test the server:"
    echo "  curl http://localhost:8080/v1/models"
    echo ""
else
    echo ""
    echo "❌ Build failed!"
    exit 1
fi

# Cleanup (optional)
# echo ""
# read -p "Do you want to remove the copied wheel files? (y/N) " -n 1 -r
# echo
# if [[ $REPLY =~ ^[Yy]$ ]]; then
#     rm -rf "$WHEEL_DEST_DIR"
#     echo "✓ Cleaned up wheel files"
# fi

# Made with Bob
