ENV ?= uat
DIR  = envs/$(ENV)
TF   = terraform -chdir=$(DIR)

.PHONY: init plan apply output fmt validate destroy-plan

init:
	$(TF) init -backend-config=../backend.hcl -reconfigure

plan:
	$(TF) plan -lock-timeout=120s -out=tfplan

apply:
	$(TF) apply -lock-timeout=300s tfplan

output:
	$(TF) output

fmt:
	terraform fmt -recursive

validate: fmt
	@for d in bootstrap envs/global envs/uat envs/prod; do \
	  echo "== $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; \
	done

destroy-plan:
	$(TF) plan -destroy -lock-timeout=120s
