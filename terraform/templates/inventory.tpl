[control_plane]
%{ for i, ip in control_plane_ips ~}
cp-${i + 1} ansible_host=${ip} ansible_user=root
%{ endfor ~}

[workers]
%{ for i, ip in worker_ips ~}
worker-${i + 1} ansible_host=${ip} ansible_user=root
%{ endfor ~}

[k8s_cluster:children]
control_plane
workers

[k8s_cluster:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[load_balancers]
%{ for i, ip in lb_ips ~}
lb-${i + 1} ansible_host=${ip} ansible_user=root
%{ endfor ~}

[load_balancers:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
