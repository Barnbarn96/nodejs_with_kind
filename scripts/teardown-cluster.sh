#!/usr/bin/env bash
set -euo pipefail
kind delete cluster --name inter || true