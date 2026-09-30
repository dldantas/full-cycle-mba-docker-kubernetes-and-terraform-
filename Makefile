TF_DIR     := infra/terraform
CHART_DIR  := infra/helm/mural
KUBECONFIG := $(CURDIR)/$(TF_DIR)/.kube/mural-config
URL        ?= http://mural.localtest.me
TF         := terraform -chdir=$(TF_DIR)

export KUBECONFIG

.PHONY: help up down plan idempotency test status logs load-test lint cycle compose-up compose-down

help: ## Lista os alvos
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

up: ## Cria cluster kind + imagens + Traefik + chart (terraform apply)
	$(TF) init -input=false
	$(TF) apply -auto-approve -input=false
	@$(MAKE) --no-print-directory test

down: ## Remove tudo (terraform destroy)
	$(TF) destroy -auto-approve -input=false

plan: ## terraform plan
	$(TF) plan

idempotency: ## Falha se o próximo apply fosse mudar algo
	$(TF) plan -detailed-exitcode -input=false >/dev/null && echo "OK: nenhuma mudança pendente (idempotente)"

test: ## Smoke test: front e API respondendo pelo Ingress
	@curl -fsS --retry 30 --retry-delay 2 --retry-all-errors -o /dev/null $(URL)/ && echo "front OK: $(URL)/"
	@curl -fsS --retry 30 --retry-delay 2 --retry-all-errors $(URL)/api/messages && echo && echo "api   OK: $(URL)/api/messages"

status: ## Recursos no namespace mural
	kubectl -n mural get pods,svc,ingress,pvc,job,hpa

logs: ## Logs da migração e da API
	kubectl -n mural logs job/mural-migrate
	kubectl -n mural logs deploy/mural-api --tail=20

load-test: ## Bônus: gera carga com hey e mostra o HPA escalando
	sh infra/scripts/load-test.sh

lint: ## helm lint + terraform fmt/validate
	helm lint $(CHART_DIR) --set database.password=lint
	$(TF) fmt -check -recursive
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate

cycle: ## Prova completa: apply -> apply (0 changed) -> destroy
	$(MAKE) --no-print-directory up
	$(MAKE) --no-print-directory idempotency
	$(MAKE) --no-print-directory down

compose-up: ## Sobe a app com docker compose (só para desenvolvimento)
	@test -f .env || { sed "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$$(openssl rand -hex 16)/" .env.example > .env && echo ".env criado com senha aleatória"; }
	docker compose up -d
	@curl -fsS --retry 40 --retry-delay 3 --retry-all-errors -o /dev/null http://localhost:8080/api/messages && echo "compose OK: http://localhost:8080"

compose-down: ## Derruba o compose e apaga o volume
	docker compose down -v
