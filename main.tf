# Start Custom Mantra Bio code
data "local_file" "mantrabio_ca" {
  filename = "${path.module}/mantrabio-root-ca.crt"
}

# End Custom Mantra Bio code
resource "google_compute_region_health_check" "backend_service_loadbalancer_health_check" {
  name                = "${var.project}-at-backend-svc-lb-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10
  region              = var.region

  http_health_check {
    port         = 9998
    request_path = "/"
  }
}

locals {
  # The health check for external NLBs come from these 3 CIDRs.
  healthcheck_prober_ip_ranges = ["35.191.0.0/16", "209.85.152.0/22", "209.85.204.0/22"]
}

resource "google_compute_region_backend_service" "accesstier" {
  name                  = "${var.project}-at-backend-svc"
  health_checks         = [google_compute_region_health_check.backend_service_loadbalancer_health_check.id]
  load_balancing_scheme = "EXTERNAL"
  protocol              = "TCP"
  region                = var.region
  backend {
    group = google_compute_region_instance_group_manager.accesstier_rigm.instance_group
  }
}

resource "google_compute_forwarding_rule" "accesstier" {
  name                  = "${var.project}-at-backend-svc-forwarding-rule"
  region                = var.region
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  ports                 = [80, 443, 8443, 9998, var.tunnel_port]
  backend_service       = google_compute_region_backend_service.accesstier.id
  ip_address            = google_compute_address.external.address
}


resource "google_compute_region_autoscaler" "accesstier" {
  name   = "${var.project}-at-rigm-autoscaler"
  target = google_compute_region_instance_group_manager.accesstier_rigm.id

  region = var.region
  autoscaling_policy {
    max_replicas = 10
    min_replicas = var.minimum_num_of_instances
    cpu_utilization {
      target = 0.8
    }
  }
}

resource "google_compute_region_instance_group_manager" "accesstier_rigm" {
  name = "${var.project}-at-rigm"

  base_instance_name = "${var.project}-accesstier"
  region             = var.region
  version {
    instance_template = google_compute_instance_template.accesstier_template.id
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.accesstier_health_check.id
    initial_delay_sec = 180
  }

  update_policy {
    minimal_action               = "REPLACE"
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }
}


resource "google_compute_health_check" "accesstier_health_check" {
  name                = "${var.project}-at-autohealing-hc"
  check_interval_sec  = 30
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    request_path = "/"
    port         = "9998"
  }
}

resource "google_compute_instance_template" "accesstier_template" {
  name_prefix = "${var.project}-at-template-"
  description = "This template is used for access tiers"

  tags         = setunion(google_compute_firewall.accesstier_ports.target_tags, google_compute_firewall.accesstier_ssh.target_tags, google_compute_firewall.healthcheck.target_tags, google_compute_firewall.accesstier_ports_tunnel.target_tags, var.tags)
  region       = var.region
  machine_type = var.machine_type

  lifecycle {
    create_before_destroy = true
  }

  disk {
    source_image = data.google_compute_image.accesstier_image.self_link
    disk_size_gb = 20
    disk_type    = "pd-ssd"
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.accesstier_subnet.name
    access_config {
      // Ephemeral public IP. Load balancer IP is static and used as access tier endpoint
    }
  }

  metadata_startup_script = join(" ", concat([
    "#!/bin/bash -ex \n",
    "echo '* soft nofile 100000' >> /etc/security/limits.d/banyan.conf \n",
    "echo '* hard nofile 100000' >> /etc/security/limits.d/banyan.conf \n",
    "echo 'fs.file-max = 100000' >> /etc/sysctl.d/90-banyan.conf \n",
    "sysctl -w fs.file-max=100000 \n",
    "echo 'options nf_conntrack hashsize=65536' >> /etc/modprobe.d/banyan.conf \n",
    "modprobe nf_conntrack \n",
    "echo '65536' > /proc/sys/net/netfilter/nf_conntrack_buckets \n",
    "echo '262144' > /proc/sys/net/netfilter/nf_conntrack_max \n",
    "# Setting up an iptables DNAT to fix google's UDP load balancers DSR implementation, which forward the traffic with an untranslated destination \n",
    "apt-get update \n",
    "# Need to trust the mantrabio-ca certificate to enable TLS",
    "apt-get install ca-certificates -y",
    "echo \"${data.local_file.mantrabio_ca.content}\" > /usr/local/share/ca-certificates/mantrabio-root-ca.crt",
    "update-ca-certificates",
    "export DEBIAN_FRONTEND=noninteractive; apt-get -y install iptables-persistent && echo 'iptables persistent installed' \n",
    "iptables -t nat -I PREROUTING -p udp --dport ${var.tunnel_port} -j DNAT --to-destination $(hostname -i) && echo 'DNAT rule applied' \n",
    "echo 'installing Netagent' \n",
    var.datadog_api_key != null ? "curl -L https://s3.amazonaws.com/dd-agent/scripts/install_script.sh | DD_AGENT_MAJOR_VERSION=7 DD_API_KEY=${var.datadog_api_key} DD_SITE=datadoghq.com bash -v \n" : "",
    "curl https://www.banyanops.com/onramp/deb-repo/banyan.key | apt-key add -\n",
    var.staging_repo != null ? "apt-add-repository \"deb https://www-stage.bnntest.com/onramp/deb-repo xenial main\" \n" : "apt-add-repository \"deb https://www.banyanops.com/onramp/deb-repo xenial main\" \n",
    var.netagent_version != null ? "apt-get update && apt-get install -y banyan-netagent2=${var.netagent_version} \n" : "apt-get update && apt-get install -y banyan-netagent2 \n",
    "cd /opt/banyan-packages \n",
    "export ACCESS_TIER_NAME=${var.name} \n",
    "export API_KEY_SECRET=${banyan_api_key.accesstier.secret} \n",
    "export COMMAND_CENTER_URL=${var.banyan_host} \n",
    "./install \n",
  ], var.custom_user_data))
}

resource "google_compute_firewall" "accesstier_ssh" {
  name          = "${var.project}-accesstier-ssh"
  network       = data.google_compute_network.accesstier_network.name
  target_tags   = ["${var.project}-accesstier-ssh"]
  source_ranges = var.management_cidrs
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "accesstier_ports" {
  name          = "${var.project}-accesstier-ports"
  network       = data.google_compute_network.accesstier_network.name
  target_tags   = ["${var.project}-accesstier-ports"]
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8443"]
  }
}

resource "google_compute_firewall" "accesstier_ports_tunnel" {
  name          = "${var.project}-accesstier-ports-tunnel"
  network       = data.google_compute_network.accesstier_network.name
  target_tags   = ["${var.project}-accesstier-ports-tunnel"]
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "udp"
    ports    = [tostring(var.tunnel_port)]
  }
}

// Allow access to the healthcheck
resource "google_compute_firewall" "healthcheck" {
  name          = "${var.project}-accesstier-healthcheck"
  network       = data.google_compute_network.accesstier_network.name
  target_tags   = ["${var.project}-accesstier-healthcheck"]
  source_ranges = local.healthcheck_prober_ip_ranges
  allow {
    protocol = "tcp"
    ports    = ["9998"]
  }
}

data "google_compute_image" "accesstier_image" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

// networking
data "google_compute_network" "accesstier_network" {
  name = var.network
}

data "google_compute_subnetwork" "accesstier_subnet" {
  name   = var.subnetwork
  region = var.region
}

resource "google_compute_address" "external" {
  name         = "${var.project}-ip-address-at-backend-svc"
  region       = var.region
  address_type = "EXTERNAL"
}