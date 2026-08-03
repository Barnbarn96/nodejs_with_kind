#!/usr/bin/env bash
set -euo pipefail
IMAGE_NAME="kind-api:latest"
kind load docker-image ${IMAGE_NAME} --name inter