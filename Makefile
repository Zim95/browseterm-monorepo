include env.mk

dev_build:
	./scripts/development/dev_build.sh $(REPO_NAME) $(USER_NAME) $(NAMESPACE) $(CERT_MANAGER_HOST_DIR)

.PHONY: dev_build
