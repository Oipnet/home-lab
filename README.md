# Home Lab — Kubernetes sur Scaleway + Plex

Cluster Kubernetes de 3 nœuds déployé sur Scaleway (~65 €/mois). Plex est accessible localement (NodePort) et depuis l'extérieur via WireGuard. Le stockage est local sur un worker dédié.

> **NAS** : l'intégration NAS/NFS sera ajoutée dans une prochaine étape.

## Architecture

```
Internet
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
│  └──────────────┘                                     │  │
│                                                        │  │
│  ┌──────────────┐  ┌──────────────┐                   │  │
│  │  worker-1    │  │  worker-2    │                   │  │
│  │  DEV1-M      │  │  DEV1-S      │                   │  │
│  │  storage=plex│  │  (léger)     │                   │  │
│  │  /data/plex  │  │              │                   │  │
│  └──────────────┘  └──────────────┘                   │  │
└──────────────────────────────────────────────────────────┘
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
│       ├── common.yml       # containerd, kubeadm, dossiers Plex
│       ├── kubernetes.yml   # kubeadm init → Flannel → join → labels
│       └── wireguard.yml    # wg0 (VPN Plex clients)
├── kubernetes/
│   ├── namespaces/plex.yaml
│   ├── storage/local-storage-class.yaml
│   ├── plex/
│   │   ├── deployment.yaml          # nodeSelector: storage=plex
│   │   ├── service.yaml             # NodePort + ClusterIP
│   │   ├── persistent-volume.yaml   # local sur worker-1
│   │   └── persistent-volume-claim.yaml
│   └── secrets/plex-claim-token.yaml.example
├── wireguard/
│   └── client-vpn/
│       └── client-wg0.conf.example
├── scripts/
│   ├── init-cluster.sh          # Bootstrap complet
│   ├── validate-k8s.sh          # kubeval + kube-score
│   └── gen-wireguard-client.sh  # Config client + QR code
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
```

> `.env` est gitignored — ne jamais le committer. Les scripts le chargent automatiquement.

### 2. Configurer Terraform et Ansible

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Remplir : allowed_ssh_cidrs avec votre IP, ssh_public_key_path

# Vault Ansible — vide pour l'instant (sera complété lors de l'intégration NAS)
cp ansible/group_vars/all/vault.yml.example ansible/group_vars/all/vault.yml
```

### 3. Bootstrap complet

```bash
# .env est chargé automatiquement — pas besoin d'export manuel
./scripts/init-cluster.sh all
```

Ou étape par étape :

```bash
./scripts/init-cluster.sh terraform    # 1. Provisionner les VMs
./scripts/init-cluster.sh common       # 2. Installer containerd + kubeadm
./scripts/init-cluster.sh kubernetes   # 3. Init cluster + labelliser worker-1
./scripts/init-cluster.sh wireguard    # 4. Configurer WireGuard
./scripts/init-cluster.sh workloads    # 5. Déployer Plex
```

### 4. Accéder à Plex

**Local** : `http://<IP-worker-1>:32400/web`

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

Plex utilise du stockage **local** sur `worker-1` (labellisé `storage=plex`) :

| Volume | Chemin sur worker-1 | Taille |
|--------|--------------------|---------|
| Config | `/data/plex/config` | 10 Gi |
| Média | `/data/plex/media` | 500 Gi |
| Transcode | `emptyDir` (ephémère) | 20 Gi |

Les dossiers sont créés par Ansible (`common.yml`). Le `nodeSelector: storage=plex` dans le Deployment garantit que Plex ne tourne que sur ce worker.

## WireGuard — VPN clients Plex

| Nœud | Interface | Adresse VPN |
|------|-----------|-------------|
| Control plane | wg0 | 10.201.0.1/24 |
| Client 1 | wg0 | 10.201.0.2/32 |
| Client 2 | wg0 | 10.201.0.3/32 |

## Pare-feu — ports ouverts

| Port | Proto | Usage |
|------|-------|-------|
| 22 | TCP | SSH (restreindre à votre IP) |
| 6443 | TCP | Kubernetes API |
| 51820 | UDP | WireGuard Plex VPN |
| 30000-32767 | TCP | NodePort (Plex sur 32400) |

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
| `ansible/group_vars/all/vault.yml` | Secrets Ansible (vide pour l'instant) | gitignored |
| `kubernetes/secrets/*.yaml` | Secrets Kubernetes en clair | gitignored |
| `.kube/config` | Kubeconfig admin | gitignored |
| `wireguard/client-vpn/clients/*/private.key` | Clés privées WireGuard | gitignored |

Seuls les fichiers `*.example` sont commités — ils ne contiennent aucune vraie valeur.

## Prochaines étapes

- [ ] Intégration NAS (WireGuard wg1 cluster↔NAS + NFS StorageClass)
- [ ] Haute disponibilité (3 control planes)
- [ ] Ingress Controller (Traefik ou nginx)
- [ ] Cert-manager + HTTPS
