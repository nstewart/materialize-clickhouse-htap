#!/bin/bash
set -euo pipefail

# Amazon Linux 2023 bootstrap — installs Docker, Docker Compose plugin, and Python 3.
# Writes /tmp/user-data-complete when done so deploy.sh knows it's safe to proceed.

dnf update -y
dnf install -y docker python3 python3-pip make

systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# Docker Compose plugin (architecture-aware)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  COMPOSE_ARCH="x86_64" ;;
  aarch64) COMPOSE_ARCH="aarch64" ;;
  *)       echo "Unsupported architecture: $ARCH" && exit 1 ;;
esac

COMPOSE_VERSION=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest \
  | grep '"tag_name"' | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

touch /tmp/user-data-complete
