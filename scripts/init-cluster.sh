#!/usr/bin/env bash
# init-cluster.sh — Full bootstrapping sequence after Terraform provisioning.
# Run from the repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/ansible"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"

# ── Charger .env si présent ───────────────────────────────────────────────────
if [[ -f "$REPO_ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "$REPO_ROOT/.env" && set +a
fi

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Dependency checks ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing tools: ${missing[*]}"
}

# ── Step 1: Terraform apply ──────────────────────────────────────────────────
terraform_apply() {
  check_deps terraform
  info "Step 1/5 — Terraform: provisioning Scaleway VMs..."
  cd "$REPO_ROOT/terraform"

  [[ -f terraform.tfvars ]] || die "terraform.tfvars not found. Copy terraform.tfvars.example and fill in values."

  if [[ ! -d .terraform ]]; then
    terraform init -upgrade
  fi
  terraform validate
  terraform apply -auto-approve

  info "Generating Ansible inventory from Terraform output..."
  terraform output -raw ansible_inventory > "$ANSIBLE_DIR/inventory/hosts.ini"
  info "Inventory written to ansible/inventory/hosts.ini"
  cd "$REPO_ROOT"
}

# ── Step 2: Ansible — common prereqs ─────────────────────────────────────────
ansible_common() {
  check_deps ansible ansible-playbook ansible-vault
  info "Step 2/5 — Ansible: installing prerequisites on all nodes..."
  cd "$ANSIBLE_DIR"
  ansible-playbook playbooks/common.yml \
    --vault-password-file ~/.ansible-vault-pass \
    -e @group_vars/all.yml \
    -v
  cd "$REPO_ROOT"
}

# ── Step 3: Ansible — Kubernetes ─────────────────────────────────────────────
ansible_kubernetes() {
  check_deps ansible ansible-playbook ansible-vault
  info "Step 3/5 — Ansible: initializing Kubernetes cluster..."
  cd "$ANSIBLE_DIR"
  ansible-playbook playbooks/kubernetes.yml \
    --vault-password-file ~/.ansible-vault-pass \
    -e @group_vars/all.yml \
    -v
  cd "$REPO_ROOT"
}

# ── Step 4: Ansible — WireGuard ──────────────────────────────────────────────
ansible_wireguard() {
  check_deps ansible ansible-playbook ansible-vault
  info "Step 4/5 — Ansible: configuring WireGuard VPNs..."
  cd "$ANSIBLE_DIR"
  ansible-playbook playbooks/wireguard.yml \
    --vault-password-file ~/.ansible-vault-pass \
    -e @group_vars/all.yml \
    -v
  cd "$REPO_ROOT"
}

# ── Step 5: Deploy Kubernetes workloads ─────────────────────────────────────
deploy_workloads() {
  check_deps kubectl
  info "Step 5/5 — Kubernetes: deploying Plex (local storage)..."
  export KUBECONFIG="$REPO_ROOT/.kube/config"

  # StorageClass locale (pas de provisioner externe nécessaire)
  kubectl apply -f "$REPO_ROOT/kubernetes/storage/local-storage-class.yaml"

  kubectl apply -f "$REPO_ROOT/kubernetes/namespaces/"
  kubectl apply -f "$REPO_ROOT/kubernetes/plex/persistent-volume.yaml"
  kubectl apply -f "$REPO_ROOT/kubernetes/plex/persistent-volume-claim.yaml"

  warn "Créer le secret du claim token Plex avant de déployer :"
  warn "  kubectl create secret generic plex-claim-token \\"
  warn "    --from-literal=PLEX_CLAIM=\$(curl -s 'https://plex.tv/api/claim') \\"
  warn "    -n plex"
  read -rp "Appuyer sur ENTRÉE après avoir créé le secret (Ctrl+C pour annuler)..."

  kubectl apply -f "$REPO_ROOT/kubernetes/plex/deployment.yaml"
  kubectl apply -f "$REPO_ROOT/kubernetes/plex/service.yaml"

  info "Attente que Plex soit prêt..."
  kubectl rollout status deployment/plex -n plex --timeout=300s

  info "Plex est opérationnel !"
  kubectl get pods,svc -n plex
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  case "${1:-all}" in
    terraform)   terraform_apply ;;
    common)      ansible_common ;;
    kubernetes)  ansible_kubernetes ;;
    wireguard)   ansible_wireguard ;;
    workloads)   deploy_workloads ;;
    all)
      terraform_apply
      ansible_common
      ansible_kubernetes
      ansible_wireguard
      deploy_workloads
      info "Bootstrap complete!"
      ;;
    *)
      echo "Usage: $0 [terraform|common|kubernetes|wireguard|workloads|all]"
      exit 1
      ;;
  esac
}

main "$@"
