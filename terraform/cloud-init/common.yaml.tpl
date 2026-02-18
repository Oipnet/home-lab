#cloud-config
# Node role: ${node_role}  Index: ${node_index}  Project: ${project_name}

package_update: true
package_upgrade: true

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - wireguard
  - nfs-common
  - open-iscsi

# Disable swap (required by kubelet)
runcmd:
  - swapoff -a
  - sed -i '/\sswap\s/s/^/#/' /etc/fstab

  # Kernel modules for containerd / Kubernetes
  - modprobe overlay
  - modprobe br_netfilter
  - echo "overlay"       >> /etc/modules-load.d/k8s.conf
  - echo "br_netfilter"  >> /etc/modules-load.d/k8s.conf

  # Sysctl for Kubernetes networking
  - sysctl -w net.bridge.bridge-nf-call-iptables=1
  - sysctl -w net.bridge.bridge-nf-call-ip6tables=1
  - sysctl -w net.ipv4.ip_forward=1
  - echo "net.bridge.bridge-nf-call-iptables=1"  >> /etc/sysctl.d/k8s.conf
  - echo "net.bridge.bridge-nf-call-ip6tables=1" >> /etc/sysctl.d/k8s.conf
  - echo "net.ipv4.ip_forward=1"                 >> /etc/sysctl.d/k8s.conf

  # Install containerd
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update -qq
  - apt-get install -y containerd.io
  - mkdir -p /etc/containerd
  - containerd config default > /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  - systemctl restart containerd
  - systemctl enable containerd

  # Install kubeadm, kubelet, kubectl (v1.29)
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  - apt-get update -qq
  - apt-get install -y kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl
  - systemctl enable --now kubelet

  # Tag node role for later Ansible identification
  - echo "${node_role}" > /etc/homelab-node-role
  - echo "${node_index}" > /etc/homelab-node-index

final_message: |
  Cloud-init complete on ${project_name} ${node_role} node ${node_index}.
  Run Ansible playbooks to finalize cluster setup.
