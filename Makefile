# Shortcuts for the common tasks. Run `make` to list them.
.DEFAULT_GOAL := help
SHELL := /bin/bash

TF  := terraform -chdir=infra/terraform
# Ansible ignores ansible.cfg in world-writable directories, which is how
# /mnt/c looks from WSL, so point at it explicitly.
ANS := cd infra/ansible && ANSIBLE_CONFIG=ansible.cfg

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Local development --------------------------------------------------------
.PHONY: up down logs test scan
up: ## Build and run the whole app locally on http://localhost:8080
	docker compose up --build -d
	@echo "SkyBook is starting on http://localhost:8080"

down: ## Stop the local stack and delete its data
	docker compose down -v

logs: ## Follow the local stack's logs
	docker compose logs -f

test: ## Run both services' unit tests in containers
	docker run --rm -v "$(CURDIR)/services/flight-search:/app" -w /app node:24-alpine \
		sh -c "npm ci --no-audit --no-fund && npm test"
	docker run --rm -v "$(CURDIR)/services/booking-api:/app" -w /app python:3.13-slim \
		sh -c "pip install -q -r requirements-dev.txt && ruff check . && pytest"

scan: ## Scan the repo for vulnerable dependencies, secrets and misconfigurations
	trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL .

# --- Infrastructure ---------------------------------------------------------------
.PHONY: tf-init tf-plan tf-apply cluster
tf-init: ## terraform init with the OCI remote-state backend
	$(TF) init -backend-config=backend.hcl

tf-plan: ## Preview infrastructure changes
	$(TF) plan

tf-apply: ## Create or update the Oracle Cloud VM and network
	$(TF) apply

cluster: ## Configure the VM, install k3s and bootstrap Argo CD
	$(ANS) ansible-playbook site.yml --ask-vault-pass
