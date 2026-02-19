# Home Lab — Kubernetes sur Scaleway + Plex

Cluster Kubernetes de 3 nœuds déployé sur Scaleway (~65 €/mois). Plex et Headlamp sont exposés en HTTPS via Traefik + Let's Encrypt (DNS challenge OVH). La médiathèque est hébergée sur un NAS Synology DS220j monté via NFS sur un tunnel OpenVPN.

## Architecture

```
Internet
    │
    ├── :80/:443 ──► Traefik (hostPort) ──► plex.forelse.fr
    │                                   └─► headlamp.forelse.fr
    │
    ├── WireGuard wg0 (port 51820) ──► Clients externes ──► Plex
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  Scaleway — fr-par-1                                     │
│                                                          │
│  ┌──────────────┐   VPC privé                            │
│  │  cp-1        │◄───────────────────────────────────┐  │
│  │  DEV1-S      │   kubeadm API :6443                 │  │
│  │  WG server   │   WireGuard wg0 :51820              │  │
│  │  Traefik     │   hostPort :80/:443                 │  │
│  └──────────────┘                                     │  │
│                                                        │  │
│  ┌──────────────┐  ┌──────────────┐                   │  │
│  │  worker-1    │  │  worker-2    │                   │  │
│  │  DEV1-M      │  │  DEV1-S      │                   │  │
│  │  storage=plex│  │  (léger)     │                   │  │
│  │  OpenVPN tun0│  │              │                   │  │
│  └──────┬───────┘  └──────────────┘                   │  │
│         │ OpenVPN :1194 UDP                            │  │
└─────────┼────────────────────────────────────────────────┘
          │
          ▼
    NAS Synology DS220j
    /volume1/files (NFS → /data dans le pod Plex)
```

## Structure du projet

```
home-lab/
├── terraform/
│   ├── providers.tf
│   ├── main.tf              # VMs, Security Groups, VPC
│   ├── variables.tf
│   ├── outputs.tf
│   ├── cloud-init/          # Bootstrap containerd + kubeadm
│   ├── templates/           # Template inventaire Ansible
│   └── tests/scaleway_test.go
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.yml
│   ├── group_vars/all.yml
│   └── playbooks/
│       ├── site.yml
│       ├── common.yml           # containerd, kubeadm, dossiers Plex
│       ├── kubernetes.yml       # kubeadm init → Flannel → join → labels
│       ├── wireguard.yml        # wg0 (VPN clients Plex)
│       └── openvpn-nas.yml      # tun0 (tunnel NAS Synology)
├── kubernetes/
│   ├── namespaces/
│   ├── storage/
│   │   ├── local-storage-class.yaml
│   │   └── nfs-storage-class.yaml
│   ├── traefik/
│   │   ├── deployment.yaml          # hostPort :80/:443, cert OVH DNS
│   │   ├── service.yaml
│   │   ├── ingressclass.yaml
│   │   ├── rbac.yaml
│   │   ├── persistent-volume.yaml
│   │   └── persistent-volume-claim.yaml
│   ├── plex/
│   │   ├── deployment.yaml          # nodeSelector: storage=plex
│   │   ├── service.yaml
│   │   ├── ingress.yaml             # plex.forelse.fr (TLS)
│   │   ├── persistent-volume.yaml       # config locale sur worker-1
│   │   ├── persistent-volume-nas.yaml   # médiathèque NFS (NAS)
│   │   └── persistent-volume-claim.yaml
│   ├── headlamp/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml             # headlamp.forelse.fr (TLS)
│   │   └── rbac.yaml
│   └── secrets/
│       ├── plex-claim-token.yaml.example
│       └── traefik-ovh-credentials.yaml  # gitignored
├── wireguard/
│   └── client-vpn/
│       └── client-wg0.conf.example
├── scripts/
│   ├── init-cluster.sh          # Bootstrap complet
│   ├── validate-k8s.sh          # kubeval + kube-score
│   ├── gen-wireguard-client.sh  # Config client wg0 + QR code
│   └── gen-openvpn-nas.sh       # PKI + nas.ovpn pour le Synology
└── .github/workflows/
    ├── terraform.yml
    └── kubernetes.yml
```

## Prérequis

| Outil | Version minimale |
|-------|-----------------|
| Terraform | 1.6+ |
| Ansible | 2.15+ |
| kubectl | 1.29+ |
| Go | 1.21+ (Terratest) |
| WireGuard | — |
| OpenVPN | — |

Compte Scaleway avec clés API : https://console.scaleway.com/iam/api-keys

## Démarrage rapide

### 1. Configurer les credentials

```bash
git clone <repo-url> home-lab && cd home-lab

# Credentials Scaleway + variables de déploiement
cp .env.example .env
# Éditer .env avec vos clés Scaleway (voir console.scaleway.com/iam/api-keys)
```

Contenu type de `.env` :
```bash
SCW_ACCESS_KEY="SCWXXXXXXXXXXXXXXXXX"
SCW_SECRET_KEY="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
SCW_DEFAULT_PROJECT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
WORKER1_PUBLIC_IP="<IP publique de worker-1>"
```

> `.env` est gitignored — ne jamais le committer. Les scripts le chargent automatiquement.

### 2. Configurer Terraform et Ansible

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Remplir : allowed_ssh_cidrs avec votre IP, ssh_public_key_path
```

### 3. Bootstrap complet

```bash
# .env est chargé automatiquement — pas besoin d'export manuel
./scripts/init-cluster.sh all
```

Ou étape par étape :

```bash
./scripts/init-cluster.sh terraform      # 1. Provisionner les VMs
./scripts/init-cluster.sh common         # 2. Installer containerd + kubeadm
./scripts/init-cluster.sh kubernetes     # 3. Init cluster + labelliser worker-1
./scripts/init-cluster.sh wireguard      # 4. Configurer WireGuard wg0
./scripts/init-cluster.sh workloads      # 5. Déployer Plex
```

### 4. Intégration NAS Synology (optionnel)

Le NAS se connecte via un tunnel OpenVPN à worker-1. La médiathèque est ensuite montée en NFS dans le pod Plex.

```bash
# 1. Générer la PKI et le profil OpenVPN pour le NAS
./scripts/gen-openvpn-nas.sh

# 2. Déployer le serveur OpenVPN sur worker-1
./scripts/init-cluster.sh openvpn-nas

# 3. Importer openvpn/nas.ovpn dans DSM → Panneau de configuration → VPN → OpenVPN
# 4. Appliquer les manifestes Kubernetes NFS
kubectl apply -f kubernetes/storage/nfs-storage-class.yaml
kubectl apply -f kubernetes/plex/persistent-volume-nas.yaml
```

Prérequis côté NAS :
- DSM 7.x — client OpenVPN natif disponible
- NFS activé sur le partage `files` (DSM → Services de fichiers → NFS)
- Autorisation NFS pour `10.200.0.1` (IP OpenVPN de worker-1)
- Permissions Unix `755` sur la racine du partage (`/volume1/files`)

### 5. Accéder aux services

**Via HTTPS (Traefik + Let's Encrypt)** :

| Service | URL |
|---------|-----|
| Plex | https://plex.forelse.fr |
| Headlamp | https://headlamp.forelse.fr |

> **Headlamp** expose l'intégralité du cluster Kubernetes. Restreindre l'accès via VPN ou IP allowlist en production.

**Externe via WireGuard** :

Après le déploiement, le playbook Ansible affiche la clé publique WireGuard du serveur.
Renseigner dans `.env` :
```bash
SERVER_PUBLIC_IP="<IP-publique-control-plane>"
SERVER_WG0_PUBKEY="<clé-affichée-par-Ansible>"
```

Puis générer une config client :
```bash
./scripts/gen-wireguard-client.sh mon-laptop 2
# Importer wireguard/client-vpn/clients/mon-laptop/wg0.conf dans WireGuard
# Accéder à http://10.201.0.1:32400/web
```

## Stockage Plex

| Volume | Stockage | Détail | Taille |
|--------|----------|--------|--------|
| Config | Local (worker-1) | `/data/plex/config` | 10 Gi |
| Médiathèque | NFS (NAS Synology) | `/volume1/files` via OpenVPN | 10 Ti |
| Transcode | emptyDir (éphémère) | — | 20 Gi |

Le `nodeSelector: storage=plex` garantit que Plex tourne uniquement sur worker-1 (qui porte le tunnel OpenVPN tun0).

## WireGuard — VPN clients Plex

| Nœud | Interface | Adresse VPN |
|------|-----------|-------------|
| Control plane | wg0 | 10.201.0.1/24 |
| Client 1 | wg0 | 10.201.0.2/32 |
| Client 2 | wg0 | 10.201.0.3/32 |

## OpenVPN — Tunnel NAS

| Nœud | Interface | Adresse VPN |
|------|-----------|-------------|
| worker-1 (serveur) | tun0 | 10.200.0.1 |
| NAS Synology DS220j (client) | tun0 | 10.200.0.2 |

## Ingress & HTTPS

Traefik tourne sur le control plane en **hostPort** (pas de LoadBalancer externe nécessaire). Les certificats sont émis via **Let's Encrypt DNS challenge OVH** — aucun port 80 entrant requis pour la validation ACME.

| Ingress | Host | Namespace | TLS |
|---------|------|-----------|-----|
| plex | plex.forelse.fr | plex | ✅ Let's Encrypt |
| headlamp | headlamp.forelse.fr | headlamp | ✅ Let's Encrypt |

Les credentials OVH pour le DNS challenge sont dans `kubernetes/secrets/traefik-ovh-credentials.yaml` (gitignored).

## Pare-feu — ports ouverts

| Port | Proto | Nœud | Usage |
|------|-------|------|-------|
| 22 | TCP | tous | SSH (restreindre à votre IP) |
| 80 | TCP | cp-1 | Traefik HTTP (redirect → HTTPS) |
| 443 | TCP | cp-1 | Traefik HTTPS |
| 6443 | TCP | cp-1 | Kubernetes API |
| 51820 | UDP | cp-1 | WireGuard — VPN clients Plex |
| 1194 | UDP | worker-1 | OpenVPN — tunnel NAS Synology |
| 30000-32767 | TCP | workers | NodePort (Plex sur 32400) |

## Tests

```bash
# Validation manifestes (local)
./scripts/validate-k8s.sh --strict

# Terratest plan only
cd terraform/tests && go test -v -timeout 5m -run TestTerraformPlan
```

Les GitHub Actions valident automatiquement Terraform et les manifestes Kubernetes sur chaque PR.

## Secrets

| Fichier | Contenu | Protection |
|---------|---------|------------|
| `.env` | Clés Scaleway, IPs, clés WireGuard | gitignored |
| `terraform/terraform.tfvars` | Config Terraform | gitignored |
| `ansible/group_vars/all/vault.yml` | Secrets Ansible | gitignored |
| `kubernetes/secrets/*.yaml` | Secrets Kubernetes en clair | gitignored |
| `.kube/config` | Kubeconfig admin | gitignored |
| `openvpn/pki/` | PKI OpenVPN (clés privées) | gitignored |
| `openvpn/**/*.ovpn` | Profils clients OpenVPN | gitignored |
| `wireguard/client-vpn/clients/*/private.key` | Clés privées WireGuard | gitignored |

Seuls les fichiers `*.example` sont commités — ils ne contiennent aucune vraie valeur.

## Prochaines étapes

- [ ] Haute disponibilité (3 control planes)
- [ ] Middleware Traefik — auth basique ou IP allowlist sur Headlamp
