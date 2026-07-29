# SPDX-License-Identifier: Apache-2.0
variable "k8s_version" {
  description = "K8s distro version to install (an RKE2 release string, e.g. v1.36.1+rke2r1). Null falls back to the platform default from component-versions. Neutral name so a future distro hop does not change the interface."
  type        = string
  default     = null
}
