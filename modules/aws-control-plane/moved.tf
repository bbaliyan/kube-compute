# SPDX-License-Identifier: Apache-2.0
# Genesis and the other control-plane nodes were two resources and two module calls.
# These keep every existing node in place. control_plane_count is at most 5.

moved {
  from = aws_instance.control_plane
  to   = aws_instance.control_plane["0"]
}

moved {
  from = module.node_bootstrap
  to   = module.node_bootstrap["0"]
}

moved {
  from = aws_instance.control_plane_additional["1"]
  to   = aws_instance.control_plane["1"]
}

moved {
  from = module.node_bootstrap_additional["1"]
  to   = module.node_bootstrap["1"]
}

moved {
  from = aws_instance.control_plane_additional["2"]
  to   = aws_instance.control_plane["2"]
}

moved {
  from = module.node_bootstrap_additional["2"]
  to   = module.node_bootstrap["2"]
}

moved {
  from = aws_instance.control_plane_additional["3"]
  to   = aws_instance.control_plane["3"]
}

moved {
  from = module.node_bootstrap_additional["3"]
  to   = module.node_bootstrap["3"]
}

moved {
  from = aws_instance.control_plane_additional["4"]
  to   = aws_instance.control_plane["4"]
}

moved {
  from = module.node_bootstrap_additional["4"]
  to   = module.node_bootstrap["4"]
}
