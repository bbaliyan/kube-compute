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
	cat $(BOOTSTRAP)/*.sh | bash -n
	cat $(BOOTSTRAP)/*.sh | shellcheck -S warning -s bash -

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
# not list. EMULATOR (moto or fakecloud) names the emulator. It must already run
# at AWS_ENDPOINT_URL; tests/state-migration/emulator.sh starts it.
EMULATOR     ?= moto
SM_DIR       := tests/state-migration
SM_WORK      ?= /tmp/state-migration
SM_OLD_REPO  ?= https://github.com/bbaliyan/terraform-aws-kube-compute.git
SM_OLD_REF   ?= v0.9.0
SM_CASES     ?= single-ids single-names multi-ids multi-names arm ha names-zone names-full names-vpcs
# A sed expression applied to the branch's root *.tf files, for the self-test.
SM_NEW_SED   ?=
# Prefix of a step whose wall time the log shows.
sm_time = TIMEFORMAT='state-migration: $(1) took %0Rs'; time
SM_EMULATOR_PORT ?= 4566
# Every tofu call of the check runs under sm_aws: it drops each AWS_* variable of the caller
# (profile, session token, endpoints) and sets dummy credentials and a loopback endpoint, so
# the check cannot reach real AWS. It is set in the recipes, so no other target is affected.
sm_aws = env $$(env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=.*/-u \1/p') \
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true \
  AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
  AWS_ENDPOINT_URL=http://127.0.0.1:$(SM_EMULATOR_PORT)

.PHONY: state-migration state-migration-seed state-migration-selftest state-migration-ci

state-migration: $(SM_CASES:%=state-migration/%)

state-migration-seed:
	@echo "state-migration: emulator $(EMULATOR) at http://127.0.0.1:$(SM_EMULATOR_PORT)"
	@out=$$(curl -fsS -X POST -d 'Action=DescribeVpcs&Version=2016-11-15' http://127.0.0.1:$(SM_EMULATOR_PORT)) \
	  || { echo "state-migration: no emulator answers on port $(SM_EMULATOR_PORT); run emulator.sh $(EMULATOR) start" >&2; exit 1; }; \
	case "$$out" in *example-vpc*) echo "state-migration: the emulator is not empty; run emulator.sh $(EMULATOR) start" >&2; exit 1;; esac
	rm -rf $(SM_WORK) && mkdir -p $(SM_WORK)
	cp -r $(SM_DIR)/seed $(SM_WORK)/seed
	$(call sm_time,seed init) $(sm_aws) tofu -chdir=$(SM_WORK)/seed init -input=false >/dev/null
	$(call sm_time,seed apply) $(sm_aws) tofu -chdir=$(SM_WORK)/seed apply -input=false -auto-approve -parallelism=30 >$(SM_WORK)/seed/apply.log
	$(sm_aws) tofu -chdir=$(SM_WORK)/seed output -json | jq -r 'to_entries[] | "s|@\(.key)@|\(.value.value)|g"' >$(SM_WORK)/seed.sed
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
	  $(call sm_time,$* $$side init) $(sm_aws) tofu -chdir=$(SM_WORK)/$*/$$side init -input=false -backend-config=path=$(SM_WORK)/$*/terraform.tfstate >$(SM_WORK)/$*/$$side-init.log; \
	done
	$(call sm_time,$* old apply) $(sm_aws) tofu -chdir=$(SM_WORK)/$*/old apply -input=false -auto-approve -parallelism=30 >$(SM_WORK)/$*/apply.log
	$(call sm_time,$* new plan) $(sm_aws) tofu -chdir=$(SM_WORK)/$*/new plan -input=false -refresh=false -parallelism=30 -out=$(SM_WORK)/$*/plan >$(SM_WORK)/$*/plan.log
	$(call sm_time,$* show) $(sm_aws) tofu -chdir=$(SM_WORK)/$*/new show -json $(SM_WORK)/$*/plan | jq -r -f $(SM_DIR)/changes.jq | sort >$(SM_WORK)/$*/changes.txt
	@echo "state-migration/$*: $(SM_OLD_REF) -> this branch"; cat $(SM_WORK)/$*/changes.txt
	@{ grep -E '^(update|create|delete|forget|replace) ' $(SM_WORK)/$*/changes.txt || true; } \
	  | { grep -vxF -f $(SM_DIR)/allowed/$*.txt || true; } | sed 's/^/unexpected: /' | { ! grep . >&2; }

# CI entry point: installs the pinned moto in a venv, starts it on the loopback
# port the check uses, and runs every case in parallel.
SM_MOTO_VERSION ?= 5.2.5
SM_MOTO_VENV    ?= /tmp/moto-venv
state-migration-ci:
	python3 -m venv $(SM_MOTO_VENV)
	$(SM_MOTO_VENV)/bin/pip install --quiet 'moto[server]==$(SM_MOTO_VERSION)'
	SM_MOTO_BIN=$(SM_MOTO_VENV)/bin/moto_server $(SM_DIR)/emulator.sh moto start
	$(MAKE) -j9 -k state-migration EMULATOR=moto

# Renames the control-plane module without a moved block. The check must fail.
state-migration-selftest:
	! $(MAKE) state-migration/single-ids SM_WORK=$(SM_WORK)-selftest \
	  SM_NEW_SED='s/module "control_plane"/module "control_plane_renamed"/; s/module\.control_plane\./module.control_plane_renamed./g' \
	  2>&1 | tee $(SM_WORK)-selftest.log
	grep -q '^unexpected: delete module\.control_plane\.aws_instance\.' $(SM_WORK)-selftest.log
	@echo "state-migration-selftest: the check failed on a rename without a moved block, as it must"
