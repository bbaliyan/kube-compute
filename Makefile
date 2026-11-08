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

# state-migration applies the released AWS module to an AWS emulator, then
# plans this branch on the same state. It fails if the plan creates, deletes
# or replaces a resource that tests/state-migration/allowed/<case>.txt does
# not list. The emulator must already run at AWS_ENDPOINT_URL.
SM_DIR       := tests/state-migration
SM_WORK      ?= /tmp/state-migration
SM_OLD_REPO  ?= https://github.com/bbaliyan/terraform-aws-kube-compute.git
SM_OLD_REF   ?= v0.9.0
SM_CASES     ?= single multi ha
# A sed expression applied to the branch's root *.tf files, for the self-test.
SM_NEW_SED   ?=
# Prefix of a step whose wall time the log shows.
sm_time = TIMEFORMAT='state-migration: $(1) took %0Rs'; time
export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test

.PHONY: state-migration state-migration-seed state-migration-selftest

state-migration: $(SM_CASES:%=state-migration/%)

state-migration-seed:
	@test -n "$${AWS_ENDPOINT_URL:-}" || { echo "state-migration: set AWS_ENDPOINT_URL to the emulator" >&2; exit 1; }
	rm -rf $(SM_WORK) && mkdir -p $(SM_WORK)
	cp -r $(SM_DIR)/seed $(SM_WORK)/seed
	$(call sm_time,seed init) tofu -chdir=$(SM_WORK)/seed init -input=false >/dev/null
	$(call sm_time,seed apply) tofu -chdir=$(SM_WORK)/seed apply -input=false -auto-approve -parallelism=30 >$(SM_WORK)/seed/apply.log
	tofu -chdir=$(SM_WORK)/seed output -json | jq -r 'to_entries[] | "s|@\(.key)@|\(.value.value)|g"' >$(SM_WORK)/seed.sed
	$(call sm_time,clone) git clone -q --depth 1 --branch $(SM_OLD_REF) $(SM_OLD_REPO) $(SM_WORK)/old
	git init -q $(SM_WORK)/new
	scripts/release-split.sh aws $(SM_WORK)/new $(CURDIR)

state-migration/%: state-migration-seed
	rm -rf $(SM_WORK)/$*
	for side in old new; do \
	  mkdir -p $(SM_WORK)/$*/$$side; \
	  cp -r $(SM_WORK)/$$side/. $(SM_WORK)/$*/$$side/; rm -rf $(SM_WORK)/$*/$$side/.git; \
	  cp $(SM_DIR)/root/*.tf $(SM_WORK)/$*/$$side/; \
	  sed -f $(SM_WORK)/seed.sed $(SM_DIR)/cases/common.auto.tfvars >$(SM_WORK)/$*/$$side/common.auto.tfvars; \
	  sed -f $(SM_WORK)/seed.sed $(SM_DIR)/cases/$*.tfvars >$(SM_WORK)/$*/$$side/terraform.tfvars; \
	  $(if $(SM_NEW_SED),[ $$side = old ] || sed -i -e '$(SM_NEW_SED)' $(SM_WORK)/$*/new/*.tf;) \
	  $(call sm_time,$* $$side init) tofu -chdir=$(SM_WORK)/$*/$$side init -input=false -backend-config=path=$(SM_WORK)/$*/terraform.tfstate >$(SM_WORK)/$*/$$side-init.log; \
	done
	$(call sm_time,$* old apply) tofu -chdir=$(SM_WORK)/$*/old apply -input=false -auto-approve -parallelism=30 >$(SM_WORK)/$*/apply.log
	$(call sm_time,$* new plan) tofu -chdir=$(SM_WORK)/$*/new plan -input=false -refresh=false -parallelism=30 -out=$(SM_WORK)/$*/plan >$(SM_WORK)/$*/plan.log
	$(call sm_time,$* show) tofu -chdir=$(SM_WORK)/$*/new show -json $(SM_WORK)/$*/plan | jq -r -f $(SM_DIR)/changes.jq | sort >$(SM_WORK)/$*/changes.txt
	@echo "state-migration/$*: $(SM_OLD_REF) -> this branch"; cat $(SM_WORK)/$*/changes.txt
	@{ grep -E '^(create|delete|replace) ' $(SM_WORK)/$*/changes.txt || true; } \
	  | { grep -vxF -f $(SM_DIR)/allowed/$*.txt || true; } | sed 's/^/unexpected: /' | { ! grep . >&2; }

# Renames the control-plane module without a moved block. The check must fail.
state-migration-selftest:
	! $(MAKE) state-migration/single SM_WORK=$(SM_WORK)-selftest \
	  SM_NEW_SED='s/module "control_plane"/module "control_plane_renamed"/; s/module\.control_plane\./module.control_plane_renamed./g' \
	  2>&1 | tee $(SM_WORK)-selftest.log
	grep -q '^unexpected: delete module\.control_plane\.aws_instance\.' $(SM_WORK)-selftest.log
	@echo "state-migration-selftest: the check failed on a rename without a moved block, as it must"
