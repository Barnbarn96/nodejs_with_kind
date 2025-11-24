#!/bin/bash

# Run scripts one by one
./scripts/create-cluster.sh
./scripts/build-image.sh
./scripts/load-image.sh
./scripts/deploy.sh
./scripts/deploy-monitoring.sh