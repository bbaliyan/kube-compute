# SPDX-License-Identifier: Apache-2.0
# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Platform values arrive as Make variables:
#   BASE_REF             commit the branch started from; empty skips commit-messages
#   PROVIDERS            providers whose release mirror test-integration builds
#   TF_PLUGIN_CACHE_DIR  where the platform keeps downloaded providers
#   JOBS                 parallel jobs of test-commit (default: the CPUs it may use)
#
# test-commit runs its checks, each module and each test file in parallel,
# and prints the output of one job at a time. For another target, pass -j.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS    ?= /usr/share/kube-devenv/checks
MODULES   := $(patsubst %/,%,$(wildcard modules/*/))
TESTS     := $(wildcard modules/*/tests/*.tftest.hcl)
BOOTSTRAP := modules/node-bootstrap/files/bootstrap.sh
BASE_REF  ?= $(shell git rev-parse --verify --quiet origin/main)
PROVIDERS ?= proxmox aws

# nproc ignores the CPU quota of a container (docker run --cpus), so read the
# cgroup quota first. More jobs than CPUs only adds memory, not speed.
JOBS ?= $(shell read -r quota period </sys/fs/cgroup/cpu.max 2>/dev/null && [ "$$quota" != max ] \
	&& echo $$(( (quota + period - 1) / period )) || nproc)

module_of = $(patsubst %/tests/,%,$(dir $(1)))

# tofu does not create the cache directory itself, so make it at parse time.
ifneq ($(TF_PLUGIN_CACHE_DIR),)
$(shell mkdir -p $(TF_PLUGIN_CACHE_DIR))
export TF_PLUGIN_CACHE_DIR
endif

.PHONY: test-commit test-fast test-integration hooks fmt lint-bootstrap lint-scripts \
	lint-pipelines validate validate-tree scan trivyignore-expiry secrets commit-messages \
	$(MODULES:%=init/%) $(MODULES:%=validate/%) $(TESTS:%=test/%)

test-commit:
	$(MAKE) --jobs=$(JOBS) --output-sync=target --no-print-directory \
		validate scan test-fast lint-scripts lint-pipelines trivyignore-expiry commit-messages

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
	tests/check-gitlab-ci.sh

validate: $(MODULES:%=validate/%) $(TESTS:%=test/%)

$(MODULES:%=init/%): init/%:
	cd $* && tofu init -backend=false -input=false

$(MODULES:%=validate/%): validate/%: init/%
	cd $* && tofu validate

# One target per test file, so the files of one module run in parallel too.
.SECONDEXPANSION:
$(TESTS:%=test/%): test/%: init/$$(call module_of,$$*)
	cd $(call module_of,$*) && tofu test -filter=tests/$(notdir $*)

# Skips .terraform, which a parallel init may be writing while trivy walks the tree.
scan:
	trivy config --skip-dirs '**/.terraform' --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore modules/

trivyignore-expiry:
	scripts/check-trivyignore.sh .trivyignore

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"

# Validates a copy, so tofu init cannot add anything (a lock file hash for this
# platform, say) to a tree that is about to be committed.
validate-tree:
	rm -rf /tmp/validate && cp -r $(TREE) /tmp/validate
	cd /tmp/validate && tofu fmt -check -recursive && tofu init -backend=false -input=false && tofu validate && tofu test

test-integration: $(addprefix mirror-,$(PROVIDERS))

mirror-%:
	rm -rf /tmp/split-$*
	git init -q /tmp/split-$*
	scripts/release-split.sh $* /tmp/split-$* $(CURDIR)
	$(MAKE) validate-tree TREE=/tmp/split-$*
