# Cluster-level helpers that apply manifests from ../puhtaeto_infra. These assume you already
# have a cluster up (see puhtaeto_infra's own README/cluster/*/README.md) and `kubectl` pointed
# at it.

observability:    ## deploy the log stack (Loki + Alloy + Grafana) into the observability namespace
	kubectl apply -f ../puhtaeto_infra/cluster/k3s/loki.yaml
	kubectl apply -f ../puhtaeto_infra/cluster/k3s/alloy.yaml
	kubectl apply -f ../puhtaeto_infra/cluster/k3s/grafana.yaml

observability_teardown:  ## remove the observability stack (Loki/Alloy/Grafana + its namespace)
	kubectl delete namespace observability --ignore-not-found

letsencrypt_issuer: ## apply the production Let's Encrypt ClusterIssuers (needs official cert-manager + a public domain)
	kubectl apply -f ../puhtaeto_infra/cluster/k3s/letsencrypt-issuer.yaml

detect_language:  ## regenerate the dummy per-language files that keep GitHub's language stats honest
	python 01_language_detection/generate_language_representation.py

.PHONY: observability observability_teardown letsencrypt_issuer detect_language
