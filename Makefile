# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Platform values arrive as Make variables:
#   BASE_REF             commit the branch started from; empty skips commit-messages
#   PROVIDER             proxmox or aws, for test-integration
#   TF_PLUGIN_CACHE_DIR  where the platform keeps downloaded providers

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS    ?= /usr/share/kube-devenv/checks
MODULES   := $(wildcard modules/*/)
BOOTSTRAP := modules/node-bootstrap/files/bootstrap.sh
BASE_REF  ?= $(shell git rev-parse --verify --quiet origin/main)
PROVIDER  ?= proxmox
SPLIT_DIR ?= /tmp/split-$(PROVIDER)

ifneq ($(TF_PLUGIN_CACHE_DIR),)
$(shell mkdir -p $(TF_PLUGIN_CACHE_DIR))
export TF_PLUGIN_CACHE_DIR
endif

.PHONY: test-commit test-fast test-integration hooks fmt lint-bootstrap lint-scripts \
	lint-pipelines validate validate-tree scan trivyignore secrets commit-messages

test-commit: test-fast lint-scripts lint-pipelines validate validate-tree scan trivyignore commit-messages

test-fast: fmt lint-bootstrap secrets

hooks:
	git config core.hooksPath .githooks

fmt:
	tofu fmt -check -recursive

lint-bootstrap:
	bash -n $(BOOTSTRAP)
	shellcheck -S warning $(BOOTSTRAP)

lint-scripts:
	bash -n scripts/*.sh tests/*.sh .githooks/pre-commit
	shellcheck -S warning scripts/*.sh tests/*.sh .githooks/pre-commit
	tests/check-trivyignore.sh

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .

validate:
	for d in $(MODULES); do \
		echo "== $$d =="; \
		( cd $$d && tofu init -backend=false -input=false && tofu validate && tofu test ); \
	done

scan:
	trivy config --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore modules/

trivyignore:
	scripts/check-trivyignore.sh .trivyignore

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"

validate-tree:
	rm -rf /tmp/validate && cp -r $(TREE) /tmp/validate
	cd /tmp/validate && tofu fmt -check -recursive && tofu init -backend=false -input=false && tofu validate && tofu test

test-integration:
	rm -rf $(SPLIT_DIR)
	git init -q $(SPLIT_DIR)
	scripts/release-split.sh $(PROVIDER) $(SPLIT_DIR) $(CURDIR)
	$(MAKE) validate-tree TREE=$(SPLIT_DIR)
