#!/bin/bash

# check if enough arguments are provided
if [ $# -lt 4 ]; then
    echo "Usage: $0 <repo-name> <user-name> <namespace> <cert-manager-host-dir>"
    exit 1
fi

# read arguments
REPO_NAME=$1
USER_NAME=$2
NAMESPACE=$3
CERT_MANAGER_HOST_DIR=$4

# build cert-manager
echo "Building cert-manager"
cd cert-manager/
# create env.mk file
cat > env.mk << EOF
# Environment variables for cert-manager development
REPO_NAME=$REPO_NAME
USER_NAME=$USER_NAME
NAMESPACE=$NAMESPACE
HOST_DIR=$CERT_MANAGER_HOST_DIR
EOF

make dev_build
cd ../

echo "Cert-manager built successfully"
