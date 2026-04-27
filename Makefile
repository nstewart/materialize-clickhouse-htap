.PHONY: up down init demo bench test load reset help \
        aws-debug aws-up aws-init aws-load aws-bench aws-demo aws-ssh aws-down

# Read public IP from .state/ for AWS targets that SSH into the instance
AWS_IP     := $(shell cat .state/public-ip 2>/dev/null)
AWS_KEY    := $(CURDIR)/.state/ec2-key.pem
AWS_SSH    := ssh -i $(AWS_KEY) -o StrictHostKeyChecking=no -o ServerAliveInterval=30 ec2-user@$(AWS_IP)
AWS_REMOTE := ~/app

help:
	@echo "materialize-clickhouse-htap"
	@echo ""
	@echo "Local:"
	@echo "  make up      Start all services"
	@echo "  make down    Stop and remove all services (including volumes)"
	@echo "  make init    Initialize pipeline (run after 'make up')"
	@echo "  make demo    Run live demo (price change propagation)"
	@echo "  make bench   Run performance benchmark (requires 'make load' first)"
	@echo "  make load    Seed 1M rows for benchmarking"
	@echo "  make test    Run integration test suite"
	@echo "  make reset   Full teardown and reinitialize"
	@echo ""
	@echo "AWS (ephemeral EC2 — spins up m5.2xlarge, tears it down when done):"
	@echo "  make aws-debug   Preflight checks (AWS CLI, credentials, permissions)"
	@echo "  make aws-up      Provision EC2, sync files, start Docker services"
	@echo "  make aws-init    Initialize Materialize pipeline on EC2"
	@echo "  make aws-load    Seed 1M orders on EC2"
	@echo "  make aws-bench   Run benchmark on EC2, stream output locally"
	@echo "  make aws-demo    Run live demo on EC2, stream output locally"
	@echo "  make aws-ssh     Open interactive SSH shell"
	@echo "  make aws-down    Terminate instance and delete all AWS resources"

up:
	docker compose up -d

down:
	docker compose down -v

init:
	@bash scripts/init.sh

demo:
	@python3 scripts/demo.py

load:
	@python3 benchmarks/generate_load.py --rows 1000000

bench:
	@python3 benchmarks/run_benchmarks.py

test:
	@python3 -m pytest tests/ -v --timeout=120

reset: down up
	@sleep 5
	@bash scripts/init.sh

# ── AWS targets ───────────────────────────────────────────────────────────────

aws-debug:
	@bash aws/debug.sh

aws-up:
	@bash aws/deploy.sh

aws-init:
	@$(AWS_SSH) "cd $(AWS_REMOTE) && bash scripts/init.sh"

aws-load:
	@$(AWS_SSH) "cd $(AWS_REMOTE) && python3 benchmarks/generate_load.py --rows 1000000"

aws-bench:
	@$(AWS_SSH) -t "cd $(AWS_REMOTE) && python3 benchmarks/run_benchmarks.py"

aws-demo:
	@$(AWS_SSH) -t "cd $(AWS_REMOTE) && python3 scripts/demo.py"

aws-ssh:
	@$(AWS_SSH)

aws-down:
	@bash aws/teardown.sh
