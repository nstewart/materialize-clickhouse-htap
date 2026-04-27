#!/bin/bash
set -euo pipefail
AWS_PAGER=""
export AWS_PAGER

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.state"

if [[ ! -d "$STATE_DIR" ]]; then
  echo "No .state/ directory found — nothing to tear down."
  exit 0
fi

# ── Terminate instance ────────────────────────────────────────────────────────

INSTANCE_ID_FILE="$STATE_DIR/instance-id"
if [[ -f "$INSTANCE_ID_FILE" ]]; then
  INSTANCE_ID=$(cat "$INSTANCE_ID_FILE")
  echo "Terminating instance $INSTANCE_ID ..."
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --output text > /dev/null
  echo "Waiting for termination..."
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
  echo "  Instance terminated"
  rm -f "$INSTANCE_ID_FILE" "$STATE_DIR/public-ip"
else
  echo "No instance ID found — skipping instance termination"
fi

# ── Delete security group (retry — ENI detachment takes a moment) ─────────────

SG_ID_FILE="$STATE_DIR/security-group-id"
if [[ -f "$SG_ID_FILE" ]]; then
  SG_ID=$(cat "$SG_ID_FILE")
  echo "Deleting security group $SG_ID ..."
  for i in $(seq 1 12); do
    if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
      echo "  Security group deleted"
      rm -f "$SG_ID_FILE"
      break
    fi
    if [[ $i -eq 12 ]]; then
      echo "WARNING: Could not delete security group $SG_ID after 2 minutes — remove manually" >&2
    else
      echo "  Waiting for ENI detachment... ($i/12)"
      sleep 10
    fi
  done
else
  echo "No security group ID found — skipping"
fi

# ── Delete key pair ───────────────────────────────────────────────────────────

KEY_FILE="$STATE_DIR/ec2-key.pem"
if [[ -f "$KEY_FILE" ]]; then
  echo "Deleting key pair htap-demo-key ..."
  aws ec2 delete-key-pair --key-name "htap-demo-key" 2>/dev/null || true
  rm -f "$KEY_FILE"
  echo "  Key pair deleted"
fi

# ── Clean up state ────────────────────────────────────────────────────────────

rm -rf "$STATE_DIR"
echo "  .state/ removed"
echo ""
echo "Teardown complete — no AWS resources remain."
