#!/bin/bash
AWS_PAGER=""
export AWS_PAGER

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; FAILED=1; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

FAILED=0

echo ""
echo "htap-demo AWS preflight checks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# AWS CLI
if command -v aws &>/dev/null; then
  pass "AWS CLI installed ($(aws --version 2>&1 | head -1))"
else
  fail "AWS CLI not found — install from https://aws.amazon.com/cli/"
fi

# SSH
if command -v ssh &>/dev/null; then
  pass "ssh available"
else
  fail "ssh not found"
fi

# rsync
if command -v rsync &>/dev/null; then
  pass "rsync available"
else
  fail "rsync not found"
fi

# AWS credentials
if IDENTITY=$(aws sts get-caller-identity 2>/dev/null); then
  ACCOUNT=$(echo "$IDENTITY" | grep '"Account"' | sed 's/.*": *"\(.*\)".*/\1/')
  ARN=$(echo "$IDENTITY" | grep '"Arn"' | sed 's/.*": *"\(.*\)".*/\1/')
  pass "AWS credentials valid"
  echo "       Account : $ACCOUNT"
  echo "       IAM ARN : $ARN"
else
  fail "AWS credentials not configured — run 'aws configure'"
fi

# Region
REGION=$(aws configure get region 2>/dev/null || echo "")
if [[ -n "$REGION" ]]; then
  pass "AWS region: $REGION"
else
  fail "AWS region not set — run 'aws configure' or set AWS_DEFAULT_REGION"
fi

# EC2 permissions (dry-run)
if aws ec2 describe-instances --max-results 5 --output text &>/dev/null; then
  pass "EC2 describe-instances permission OK"
else
  fail "Missing EC2 describe-instances permission"
fi

if aws ec2 run-instances --dry-run \
  --image-id ami-00000000 --instance-type m5.2xlarge \
  --key-name test --count 1 2>&1 | grep -q "DryRunOperation"; then
  pass "EC2 run-instances permission OK"
else
  fail "Missing EC2 run-instances permission"
fi

# AMI lookup — EC2_ARCH sets the target EC2 architecture (not local machine)
AMI_ARCH="${EC2_ARCH:-x86_64}"

if AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${AMI_ARCH}" \
  --query "Parameter.Value" --output text 2>/dev/null); then
  pass "AMI lookup OK: $AMI_ID"
else
  fail "Cannot look up Amazon Linux 2023 AMI via SSM (check SSM permissions)"
fi

# Existing state
STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../.state"
if [[ -f "$STATE_DIR/instance-id" ]]; then
  warn "Existing instance found: $(cat "$STATE_DIR/instance-id") — run 'make aws-down' first to start fresh"
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo -e "  ${GREEN}All checks passed — ready for 'make aws-up'${NC}"
else
  echo -e "  ${RED}Some checks failed — fix the issues above before deploying${NC}"
  exit 1
fi
echo ""
