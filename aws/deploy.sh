#!/bin/bash
set -euo pipefail
AWS_PAGER=""
export AWS_PAGER

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$REPO_ROOT/.state"
INSTANCE_TYPE="${INSTANCE_TYPE:-m5.2xlarge}"
KEY_NAME="htap-demo-key"
SG_NAME="htap-demo-sg"
SSH_USER="ec2-user"
REMOTE_DIR="~/app"

# ── Prerequisites ────────────────────────────────────────────────────────────

for cmd in aws ssh rsync; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

mkdir -p "$STATE_DIR"

# ── AMI lookup (Amazon Linux 2023) ───────────────────────────────────────────
# EC2_ARCH controls the AMI, not the local machine arch. m5 instances are
# x86_64; switch to arm64 only if using a Graviton instance type (e.g. m7g).

AMI_ARCH="${EC2_ARCH:-x86_64}"

echo "Looking up Amazon Linux 2023 AMI for $AMI_ARCH..."
AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${AMI_ARCH}" \
  --query "Parameter.Value" --output text)
echo "  AMI: $AMI_ID"

# ── SSH key pair ─────────────────────────────────────────────────────────────

KEY_FILE="$STATE_DIR/ec2-key.pem"
if [[ ! -f "$KEY_FILE" ]]; then
  echo "Creating EC2 key pair '$KEY_NAME'..."
  aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query "KeyMaterial" --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
else
  echo "Reusing existing key pair at $KEY_FILE"
fi

# ── Security group ───────────────────────────────────────────────────────────

MY_IP=$(curl -fsSL https://checkip.amazonaws.com)
echo "Your public IP: $MY_IP"

SG_ID_FILE="$STATE_DIR/security-group-id"
if [[ -f "$SG_ID_FILE" ]]; then
  SG_ID=$(cat "$SG_ID_FILE")
  echo "Reusing security group $SG_ID"
else
  echo "Creating security group '$SG_NAME'..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "htap-demo SSH access" \
    --query "GroupId" --output text)
  echo "$SG_ID" > "$SG_ID_FILE"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32"
  echo "  Security group $SG_ID created (SSH from $MY_IP only)"
fi

# ── Launch instance ───────────────────────────────────────────────────────────

INSTANCE_ID_FILE="$STATE_DIR/instance-id"
if [[ -f "$INSTANCE_ID_FILE" ]]; then
  INSTANCE_ID=$(cat "$INSTANCE_ID_FILE")
  echo "Reusing existing instance $INSTANCE_ID"
else
  echo "Launching $INSTANCE_TYPE instance..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "file://$SCRIPT_DIR/user-data.sh" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":40,"VolumeType":"gp3"}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=htap-demo}]' \
    --query "Instances[0].InstanceId" --output text)
  echo "$INSTANCE_ID" > "$INSTANCE_ID_FILE"
  echo "  Instance $INSTANCE_ID launched"
fi

# ── Wait for instance running ─────────────────────────────────────────────────

echo "Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "$PUBLIC_IP" > "$STATE_DIR/public-ip"
echo "  Public IP: $PUBLIC_IP"

# ── Wait for SSH ──────────────────────────────────────────────────────────────

SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=30"

echo "Waiting for SSH to become available..."
for i in $(seq 1 30); do
  if ssh $SSH_OPTS "${SSH_USER}@${PUBLIC_IP}" "echo ok" &>/dev/null; then
    echo "  SSH ready"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "ERROR: SSH not available after 5 minutes" >&2
    exit 1
  fi
  sleep 10
done

# ── Wait for user-data ────────────────────────────────────────────────────────

echo "Waiting for user-data (Docker + Python install) to complete..."
for i in $(seq 1 36); do
  if ssh $SSH_OPTS "${SSH_USER}@${PUBLIC_IP}" "test -f /tmp/user-data-complete"; then
    echo "  Bootstrap complete"
    break
  fi
  if [[ $i -eq 36 ]]; then
    echo "ERROR: user-data did not complete within 6 minutes" >&2
    exit 1
  fi
  sleep 10
done

# ── Sync project files ────────────────────────────────────────────────────────

echo "Syncing project files to $PUBLIC_IP:$REMOTE_DIR ..."
rsync -az --delete \
  --exclude='.git/' \
  --exclude='.state/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.venv/' \
  --exclude='venv/' \
  -e "ssh $SSH_OPTS" \
  "$REPO_ROOT/" \
  "${SSH_USER}@${PUBLIC_IP}:${REMOTE_DIR}/"
echo "  Sync complete"

# ── Install Python dependencies ───────────────────────────────────────────────

echo "Installing Python dependencies..."
ssh $SSH_OPTS "${SSH_USER}@${PUBLIC_IP}" \
  "pip3 install -q -r ${REMOTE_DIR}/requirements.txt"
echo "  Dependencies installed"

# ── Start services ────────────────────────────────────────────────────────────

echo "Starting Docker services..."
ssh $SSH_OPTS "${SSH_USER}@${PUBLIC_IP}" \
  "cd ${REMOTE_DIR} && docker compose up -d"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Instance ready: $INSTANCE_ID ($PUBLIC_IP)"
echo ""
echo "  Next steps:"
echo "    make aws-init   — initialize Materialize pipeline"
echo "    make aws-load   — seed 1M orders"
echo "    make aws-bench  — run benchmark"
echo "    make aws-demo   — run live demo"
echo "    make aws-down   — teardown everything"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
