include env.mk

# One-command deploy / teardown (Docker Desktop). See scripts/ and README §"Development Setup".
# First-time (creates + seeds the DB — DESTRUCTIVE): make setup_fresh
# Re-deploy (keeps data):                            make setup

setup:            ## deploy the whole stack (skips DB init)
	./scripts/setup.sh

setup_fresh:      ## first-time deploy incl. destructive DB init + seed
	./scripts/setup.sh --fresh

teardown:         ## remove the app stack + namespace (leaves MetalLB/ingress)
	./scripts/teardown.sh

teardown_all:     ## also remove cluster-scoped infra (MetalLB, ingress-nginx)
	./scripts/teardown.sh --all

gen_env:          ## regenerate each submodule's env.mk/.env from the aggregated env.mk
	./scripts/gen-env.sh

observability:    ## deploy the log stack (Loki + Alloy + Grafana) into the observability namespace
	kubectl apply -f 02_cluster_infra/loki.yaml
	kubectl apply -f 02_cluster_infra/alloy.yaml
	kubectl apply -f 02_cluster_infra/grafana.yaml

observability_teardown:  ## remove the observability stack (Loki/Alloy/Grafana + its namespace)
	kubectl delete namespace observability --ignore-not-found

letsencrypt_issuer: ## apply the production Let's Encrypt ClusterIssuers (needs official cert-manager + a public domain)
	kubectl apply -f 02_cluster_infra/letsencrypt-issuer.yaml

detect_language:
	python 01_language_detection/generate_language_representation.py

.PHONY: setup setup_fresh teardown teardown_all gen_env observability observability_teardown letsencrypt_issuer detect_language
