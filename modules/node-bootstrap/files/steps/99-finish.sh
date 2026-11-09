# SPDX-License-Identifier: Apache-2.0
rm -rf "$PLATFORM_DIR"
touch /run/kube-compute-boot-complete
echo "kube-compute: bootstrap complete $(date -Is)"
