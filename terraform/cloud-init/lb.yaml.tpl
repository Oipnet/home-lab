#cloud-config
# Node role: load-balancer  Index: ${node_index}  Project: ${project_name}

package_update: true
package_upgrade: true

packages:
  - haproxy
  - curl

runcmd:
  # Tag node role for later Ansible identification
  - echo "load-balancer" > /etc/homelab-node-role
  - echo "${node_index}" > /etc/homelab-node-index

final_message: |
  Cloud-init complete on ${project_name} load-balancer node ${node_index}.
  Run Ansible playbooks to finalize HAProxy configuration.
