include env.mk

dev_build:
	./scripts/development/dev_build.sh $(REPO_NAME) $(USER_NAME) $(NAMESPACE) $(CERT_MANAGER_HOST_DIR)

detect_language:
	python 01_language_detection/generate_language_representation.py

build_letsencrypt_issuer:
	

.PHONY: dev_build detect_language
