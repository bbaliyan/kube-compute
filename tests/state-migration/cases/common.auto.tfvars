# Inputs every case shares. Synthetic values in the shape a real consumer uses.
# @name@ becomes the seed output of that name.
aws_region            = "eu-west-1"
cluster_domain        = "example.internal"
hosted_zone_id        = "@hosted_zone_id@"
root_volume_size_gb   = 20
root_volume_type      = "gp3"
ingress_ports         = [80, 443, 6443]
allowed_ingress_cidrs = ["10.0.0.0/16"]
cert_mode             = "byo"
trusted_ca_in_image   = true
power_schedule        = { stop_time = "20:00", timezone = "Europe/Dublin" }
extra_tags            = { "cost-centre" = "example" }
