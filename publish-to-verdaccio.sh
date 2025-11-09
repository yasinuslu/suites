#!/usr/bin/env bash
set -euo pipefail

# Script to bump all packages to a specified version and publish to local Verdaccio
# Usage: ./publish-to-verdaccio.sh <version>
# Example: ./publish-to-verdaccio.sh 4.0.0-beta.1

VERDACCIO_PORT=4873
VERDACCIO_URL="http://localhost:${VERDACCIO_PORT}"
VERDACCIO_CONTAINER_NAME="verdaccio"
VERDACCIO_STARTED_BY_SCRIPT=false
SCRIPT_EXIT_CODE=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDACCIO_CONFIG="${SCRIPT_DIR}/e2e/config.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cleanup function (only runs on error)
cleanup() {
  # Only cleanup if script started verdaccio AND there was an error
  if [ "$VERDACCIO_STARTED_BY_SCRIPT" = true ] && [ $SCRIPT_EXIT_CODE -ne 0 ]; then
    echo -e "${YELLOW}Stopping Verdaccio container due to error...${NC}"
    docker kill "$VERDACCIO_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$VERDACCIO_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

# Set trap for cleanup on exit
trap 'SCRIPT_EXIT_CODE=$?; cleanup; exit $SCRIPT_EXIT_CODE' EXIT

# Check if version argument is provided
if [ $# -eq 0 ]; then
  echo -e "${RED}Error: Version argument is required${NC}"
  echo "Usage: $0 <version>"
  echo "Example: $0 4.0.0-beta.1"
  exit 1
fi

VERSION="$1"
echo -e "${GREEN}Starting publish process for version: ${VERSION}${NC}"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
  echo "Please install Docker to use this script"
  exit 1
fi

# Check if verdaccio config file exists
if [ ! -f "$VERDACCIO_CONFIG" ]; then
  echo -e "${RED}Error: Verdaccio config file not found at ${VERDACCIO_CONFIG}${NC}"
  exit 1
fi

# Check if verdaccio container is already running
check_verdaccio_running() {
  if docker ps --format '{{.Names}}' | grep -q "^${VERDACCIO_CONTAINER_NAME}$"; then
    return 0
  fi
  return 1
}

# Check if verdaccio is accessible
check_verdaccio_accessible() {
  if command -v curl &> /dev/null; then
    if curl -s "${VERDACCIO_URL}" > /dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# Start verdaccio container if not running
if check_verdaccio_running; then
  echo -e "${GREEN}Verdaccio container is already running${NC}"
  if ! check_verdaccio_accessible; then
    echo -e "${YELLOW}Waiting for Verdaccio to be accessible...${NC}"
    sleep 3
  fi
else
  echo -e "${YELLOW}Starting Verdaccio container...${NC}"
  
  # Kill and remove existing container if it exists (stopped)
  docker kill "$VERDACCIO_CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$VERDACCIO_CONTAINER_NAME" >/dev/null 2>&1 || true
  
  # Start verdaccio container
  if ! docker run -d --name "$VERDACCIO_CONTAINER_NAME" \
    -p "${VERDACCIO_PORT}:4873" \
    -v "${VERDACCIO_CONFIG}:/verdaccio/conf/config.yaml" \
    verdaccio/verdaccio; then
    echo -e "${RED}Error: Failed to start Verdaccio container${NC}"
    exit 1
  fi
  
  VERDACCIO_STARTED_BY_SCRIPT=true
  
  # Wait for verdaccio to be ready
  echo -e "${YELLOW}Waiting for Verdaccio to be ready...${NC}"
  sleep 3
  
  MAX_RETRIES=30
  RETRY_COUNT=0
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if check_verdaccio_accessible; then
      echo -e "${GREEN}Verdaccio is ready!${NC}"
      break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 1
  done
  
  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Error: Verdaccio failed to become accessible after ${MAX_RETRIES} seconds${NC}"
    echo "Check container logs with: docker logs $VERDACCIO_CONTAINER_NAME"
    exit 1
  fi
fi

# Bump versions using lerna
echo -e "${GREEN}Bumping all packages to version ${VERSION}...${NC}"
if ! pnpm lerna version "${VERSION}" --yes --no-git-tag-version --no-push --force-publish --no-commit-hooks; then
  echo -e "${RED}Error: Failed to bump package versions${NC}"
  exit 1
fi

# Build all packages
echo -e "${GREEN}Building all packages...${NC}"
if ! pnpm build; then
  echo -e "${RED}Error: Build failed${NC}"
  exit 1
fi

# Publish to verdaccio
echo -e "${GREEN}Publishing packages to Verdaccio at ${VERDACCIO_URL}...${NC}"
if ! pnpm lerna publish from-package --registry "${VERDACCIO_URL}" --yes --no-git-tag-version --no-push --no-git-reset; then
  echo -e "${RED}Error: Failed to publish packages${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Successfully published all packages to Verdaccio!${NC}"
echo -e "${GREEN}Verdaccio is running at ${VERDACCIO_URL}${NC}"
if [ "$VERDACCIO_STARTED_BY_SCRIPT" = true ]; then
  echo -e "${YELLOW}Note: Verdaccio container was started by this script and will continue running.${NC}"
  echo -e "${YELLOW}To stop it manually, run: docker kill $VERDACCIO_CONTAINER_NAME && docker rm $VERDACCIO_CONTAINER_NAME${NC}"
else
  echo -e "${YELLOW}Note: Verdaccio container was already running and will continue running.${NC}"
fi

