# root.hcl — anchor file for examples/consumer/live/aws/.
#
# Cluster units reference this file via find_in_parent_folders("root.hcl") to resolve
# paths relative to this directory. Carries no shared config itself — remote state and
# the module source pin live in common.hcl; the provider region lives in each region's
# region.hcl (this is the piece that makes region-scoping structural, per ADR 0001).

locals {}
