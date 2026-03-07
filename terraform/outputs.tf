output "control_plane_public_ips" {
  description = "Public IPs of control plane nodes"
  value       = scaleway_instance_ip.control_plane[*].address
}

output "worker_public_ips" {
  description = "Public IPs of worker nodes"
  value       = scaleway_instance_ip.worker[*].address
}

output "lb_public_ip" {
  description = "Public IP of the load balancer (lb-1)"
  value       = scaleway_instance_ip.lb.address
}

output "private_network_id" {
  description = "ID of the private VPC network"
  value       = scaleway_vpc_private_network.k8s.id
}

# Generates a ready-to-use Ansible inventory
output "ansible_inventory" {
  description = "Ansible inventory (INI format)"
  value = templatefile("${path.module}/templates/inventory.tpl", {
    control_plane_ips = scaleway_instance_ip.control_plane[*].address
    worker_ips        = scaleway_instance_ip.worker[*].address
    lb_ips            = [scaleway_instance_ip.lb.address]
  })
}
