.PHONY: help up down plan test policy-test lint app-test
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'
up: ## build EVERYTHING end to end and prove it works
	./scripts/up.sh
down: ## delete EVERYTHING this repo created (PURGE=1 also drops the state bucket)
	./scripts/down.sh $(if $(PURGE),--purge,)
plan: ## terraform plan only
	./scripts/up.sh --plan
test: ## live test suite against the running platform
	RUN_LOAD=1 ./scripts/test.sh
lint: ## ruff, terraform fmt/validate, kubeconform
	.venv/bin/ruff check app && .venv/bin/ruff format --check app
	terraform -chdir=terraform fmt -check -recursive && terraform -chdir=terraform validate
	for o in staging prod; do kubectl kustomize k8s/overlays/$$o | kubeconform -strict -ignore-missing-schemas -summary -; done
	kubeconform -strict -ignore-missing-schemas -summary gitops/platform gitops/apps gitops/bootstrap/project.yaml gitops/bootstrap/root.yaml
app-test: ## unit tests
	.venv/bin/pytest -q
policy-test: ## admission policies on a throwaway local cluster (needs docker + kind)
	kind create cluster --name policy-test --wait 120s
	kubectl --context kind-policy-test apply -f gitops/platform/namespaces/namespaces.yaml -f gitops/platform/policies/policies.yaml
	sleep 8; tests/admission-policies.sh kind-policy-test team-a; rc=$$?; kind delete cluster --name policy-test; exit $$rc
