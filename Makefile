ENV ?= uat
DIR  = envs/$(ENV)
TF   = terraform -chdir=$(DIR)

.PHONY: init plan apply output fmt validate destroy-plan

# Refuse to touch the wrong AWS account (envs/account.txt holds the expected 12-digit id)
check-account:
	@expected=$$(cat envs/account.txt 2>/dev/null); actual=$$(aws sts get-caller-identity --query Account --output text); \
	if [ -z "$$expected" ]; then echo "envs/account.txt missing — write the Collective account id into it"; exit 1; fi; \
	if [ "$$expected" != "$$actual" ]; then echo "WRONG ACCOUNT: credentials are for $$actual, expected $$expected (check AWS_PROFILE / env vars)"; exit 1; fi; \
	echo "account ok: $$actual"

init: check-account
	$(TF) init -backend-config=../backend.hcl -reconfigure

plan: check-account
	$(TF) plan -lock-timeout=120s -out=tfplan

apply: check-account
	$(TF) apply -lock-timeout=300s tfplan

output:
	$(TF) output

fmt:
	terraform fmt -recursive

validate: fmt
	@for d in bootstrap envs/global envs/uat envs/prod; do \
	  echo "== $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; \
	done

destroy-plan: check-account
	$(TF) plan -destroy -lock-timeout=120s
