#!/usr/bin/env bash
set -euo pipefail
IMAGE_NAME="kind-api:latest"
docker build -t ${IMAGE_NAME} .