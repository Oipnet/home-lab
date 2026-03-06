# ─────────────────────────────────────────────
# SSH Key
# ─────────────────────────────────────────────
resource "scaleway_iam_ssh_key" "homelab" {
  name       = "${var.project_name}-key"
  public_key = file(var.ssh_public_key_path)
}

# ─────────────────────────────────────────────
# Private Network (VPC)
# ─────────────────────────────────────────────
resource "scaleway_vpc_private_network" "k8s" {
  name   = "${var.project_name}-k8s-net"
  region = var.region
}

# ─────────────────────────────────────────────
# Security Groups
# ─────────────────────────────────────────────
resource "scaleway_instance_security_group" "control_plane" {
  name                    = "${var.project_name}-cp-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # SSH — une règle par CIDR autorisé
  dynamic "inbound_rule" {
    for_each = var.allowed_ssh_cidrs
    content {
      action   = "accept"
      port     = 22
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  # Kubernetes API server
  inbound_rule {
    action   = "accept"
    port     = 6443
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }

  # etcd peer
  inbound_rule {
    action     = "accept"
    port_range = "2379-2380"
    protocol   = "TCP"
    ip_range   = "0.0.0.0/0"
  }

  # kubelet, kube-scheduler, kube-controller-manager
  inbound_rule {
    action     = "accept"
    port_range = "10250-10259"
    protocol   = "TCP"
    ip_range   = "0.0.0.0/0"
  }

  # Flannel VXLAN overlay
  inbound_rule {
    action   = "accept"
    port     = 8472
    protocol = "UDP"
    ip_range = "0.0.0.0/0"
  }

  # Beszel agent — le Hub (sur worker-1) se connecte aux agents sur ce port
  # Restreint aux IPs des nœuds du cluster uniquement
  dynamic "inbound_rule" {
    for_each = concat(
      [for ip in scaleway_instance_ip.control_plane : "${ip.address}/32"],
      [for ip in scaleway_instance_ip.worker : "${ip.address}/32"]
    )
    content {
      action   = "accept"
      port     = 45876
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }
}

resource "scaleway_instance_security_group" "worker" {
  name                    = "${var.project_name}-worker-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # SSH — une règle par CIDR autorisé
  dynamic "inbound_rule" {
    for_each = var.allowed_ssh_cidrs
    content {
      action   = "accept"
      port     = 22
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  # HTTP / HTTPS — Traefik ingress (hostPort)
  inbound_rule {
    action   = "accept"
    port     = 80
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }

  inbound_rule {
    action   = "accept"
    port     = 443
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }

  # kubelet
  inbound_rule {
    action   = "accept"
    port     = 10250
    protocol = "TCP"
    ip_range = "0.0.0.0/0"
  }

  # OpenVPN — tunnel NAS Synology (tun0)
  inbound_rule {
    action   = "accept"
    port     = 1194
    protocol = "UDP"
    ip_range = "0.0.0.0/0"
  }

  # WireGuard VPN — accès sécurisé Jellyfin (wg0, worker-2)
  inbound_rule {
    action   = "accept"
    port     = 51820
    protocol = "UDP"
    ip_range = "0.0.0.0/0"
  }

  # Flannel VXLAN overlay
  inbound_rule {
    action   = "accept"
    port     = 8472
    protocol = "UDP"
    ip_range = "0.0.0.0/0"
  }

  # Beszel agent — le Hub (sur worker-1) se connecte aux agents sur ce port
  # Restreint aux IPs des nœuds du cluster uniquement
  dynamic "inbound_rule" {
    for_each = concat(
      [for ip in scaleway_instance_ip.control_plane : "${ip.address}/32"],
      [for ip in scaleway_instance_ip.worker : "${ip.address}/32"]
    )
    content {
      action   = "accept"
      port     = 45876
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }
}

# ─────────────────────────────────────────────
# Control Plane Nodes
# ─────────────────────────────────────────────
resource "scaleway_instance_server" "control_plane" {
  count = var.control_plane_count

  name  = "${var.project_name}-cp-${count.index + 1}"
  type  = var.control_plane_type
  image = var.image
  zone  = var.zone
  ip_id = scaleway_instance_ip.control_plane[count.index].id

  security_group_id = scaleway_instance_security_group.control_plane.id

  private_network {
    pn_id = scaleway_vpc_private_network.k8s.id
  }

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init/common.yaml.tpl", {
      node_role    = "control-plane"
      node_index   = count.index
      project_name = var.project_name
    })
  }

  tags = ["${var.project_name}", "control-plane", "kubernetes"]
}

# ─────────────────────────────────────────────
# Block Volume — stockage données worker-1
# ─────────────────────────────────────────────
resource "scaleway_block_volume" "worker1_data" {
  name       = "${var.project_name}-worker1-data"
  iops       = 5000
  size_in_gb = 20
  zone       = var.zone
}

# ─────────────────────────────────────────────
# Worker Nodes
# ─────────────────────────────────────────────
resource "scaleway_instance_server" "worker" {
  count = var.worker_count

  name = "${var.project_name}-worker-${count.index + 1}"
  # worker-1 (index 0) = Jellyfin + stockage local → DEV1-M
  # worker-2+ (index 1+) = workloads légers → DEV1-S
  type  = count.index == 0 ? var.media_worker_type : var.worker_type
  image = var.image
  zone  = var.zone
  ip_id = scaleway_instance_ip.worker[count.index].id

  security_group_id = scaleway_instance_security_group.worker.id

  # Volume de données supplémentaire sur worker-1 uniquement
  additional_volume_ids = count.index == 0 ? [scaleway_block_volume.worker1_data.id] : []

  private_network {
    pn_id = scaleway_vpc_private_network.k8s.id
  }

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init/common.yaml.tpl", {
      node_role    = "worker"
      node_index   = count.index
      project_name = var.project_name
    })
  }

  tags = ["${var.project_name}", "worker", "kubernetes"]
}

# ─────────────────────────────────────────────
# Flexible IPs (public IPs)
# ─────────────────────────────────────────────
resource "scaleway_instance_ip" "control_plane" {
  count = var.control_plane_count
  zone  = var.zone
}

resource "scaleway_instance_ip" "worker" {
  count = var.worker_count
  zone  = var.zone
}
