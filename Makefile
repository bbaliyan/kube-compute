# SPDX-License-Identifier: Apache-2.0
# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Platform values arrive as Make variables:
#   BASE_REF             commit the branch started from; empty skips commit-messages
#   PROVIDERS            providers whose release mirror test-integration builds
#   TF_PLUGIN_CACHE_DIR  where the platform keeps downloaded providers
#   JOBS                 parallel jobs of test-commit (default: the CPUs it may use)
#   WORK                 copy of modules/ and examples/ where validate and tests run.
#                        test-commit makes its own temporary directory and removes it.
#                        A direct `make validate` uses the fixed default, so do not run
#                        two of them at once.
#
# test-commit runs its checks, each module and each test file in parallel,
# and prints the output of one job at a time. For another target, pass -j.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS    ?= /usr/share/kube-devenv/checks
MODULES   := $(patsubst %/,%,$(wildcard modules/*/))
EXAMPLES  := $(patsubst %/,%,$(wildcard examples/*/))
UNITS     := $(MODULES) $(EXAMPLES)
WORK      ?= /tmp/kube-compute-work
TESTS     := $(wildcard modules/*/tests/*.tftest.hcl)
BOOTSTRAP := modules/node-bootstrap/files/steps
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
	work $(UNITS:%=init/%) $(UNITS:%=validate/%) $(TESTS:%=test/%)

test-commit:
	work=$$(mktemp -d) && trap 'rm -rf "$$work"' EXIT && \
	$(MAKE) --jobs=$(JOBS) --output-sync=target --no-print-directory WORK="$$work" \
		validate scan test-fast lint-scripts lint-pipelines trivyignore-expiry commit-messages

test-fast: fmt lint-bootstrap secrets

hooks:
	git config core.hooksPath .githooks

fmt:
	tofu fmt -check -recursive

lint-bootstrap:
	cat $(BOOTSTRAP)/*.sh | bash -n
	cat $(BOOTSTRAP)/*.sh | shellcheck -S warning -s bash -

lint-scripts:
	bash -n scripts/*.sh tests/*.sh .githooks/pre-commit
	shellcheck -S warning scripts/*.sh tests/*.sh .githooks/pre-commit
	tests/check-trivyignore.sh

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .
	tests/check-gitlab-ci.sh

validate: $(UNITS:%=validate/%) $(TESTS:%=test/%)

# tofu init writes .terraform and may edit a lock file, so every init, validate
# and test runs in a copy and the tree stays clean. examples/ reach modules/ by
# a relative path, so both are copied.
work:
	rm -rf $(WORK) && mkdir -p $(WORK)
	tar --exclude=.terraform -cf - modules examples | tar -xf - -C $(WORK)

$(UNITS:%=init/%): init/%: work
	cd $(WORK)/$* && tofu init -backend=false -input=false

$(UNITS:%=validate/%): validate/%: init/%
	cd $(WORK)/$* && tofu validate

# One target per test file, so the files of one module run in parallel too.
.SECONDEXPANSION:
$(TESTS:%=test/%): test/%: init/$$(call module_of,$$*)
	cd $(WORK)/$(call module_of,$*) && tofu test -filter=tests/$(notdir $*)

# Scans modules/ only. examples/ hold placeholder calls to those modules, so they add no
# findings of their own. Skips .terraform, which a local tofu init can leave in the tree.
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
