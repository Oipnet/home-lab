#!/usr/bin/env bash
# gen-wireguard-nas.sh — Génère la config WireGuard de la Freebox Ultra pour le tunnel NAS↔VPS (wg1).
# La Freebox est l'endpoint WireGuard côté domicile — le NAS Synology n'est pas touché.
#
# Pré-requis dans .env :
#   WORKER1_PUBLIC_IP  — IP publique du worker-1 (terraform output worker_public_ips)
#   SERVER_WG1_PUBKEY  — Clé publique wg1 du worker-1 (affichée par wireguard-nas.yml)
#
# Usage :
#   ./scripts/gen-wireguard-nas.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Charger .env si présent ────────────────────────────────────────────────────
if [[ -f "$REPO_ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "$REPO_ROOT/.env" && set +a
fi

# ── Vérifier wg ou proposer une alternative ───────────────────────────────────
wg_genkey() {
  if command -v wg &>/dev/null; then
    wg genkey
  elif command -v openssl &>/dev/null; then
    # Génération d'une clé privée X25519 compatible WireGuard via openssl
    openssl genpkey -algorithm X25519 2>/dev/null \
      | openssl pkey -outform DER 2>/dev/null \
      | tail -c 32 \
      | base64
  else
    echo "" >&2
    echo "ERREUR : ni 'wg' ni 'openssl' n'est disponible." >&2
    echo "" >&2
    echo "Installer wireguard-tools :" >&2
    echo "  Ubuntu/Debian/WSL : sudo apt install wireguard-tools" >&2
    echo "  macOS             : brew install wireguard-tools" >&2
    exit 1
  fi
}

wg_pubkey() {
  local privkey="$1"
  if command -v wg &>/dev/null; then
    echo "$privkey" | wg pubkey
  else
    # Dériver la clé publique X25519 depuis la clé privée base64 via openssl
    echo "$privkey" \
      | base64 -d \
      | openssl pkey -inform DER -outform DER -pubout 2>/dev/null \
      | tail -c 32 \
      | base64
  fi
}

WORKER1_PUBLIC_IP="${WORKER1_PUBLIC_IP:?Définir WORKER1_PUBLIC_IP dans .env (terraform output worker_public_ips)}"
SERVER_WG1_PUBKEY="${SERVER_WG1_PUBKEY:?Définir SERVER_WG1_PUBKEY dans .env (affiché par wireguard-nas.yml)}"

OUTPUT_DIR="$REPO_ROOT/wireguard/freebox"
mkdir -p "$OUTPUT_DIR"

# ── Générer la paire de clés Freebox ──────────────────────────────────────────
FREEBOX_PRIVATE_KEY="$(wg_genkey)"
FREEBOX_PUBLIC_KEY="$(wg_pubkey "$FREEBOX_PRIVATE_KEY")"

printf '%s' "$FREEBOX_PRIVATE_KEY" > "${OUTPUT_DIR}/freebox.key"
printf '%s' "$FREEBOX_PUBLIC_KEY"  > "${OUTPUT_DIR}/freebox.pub"
chmod 600 "${OUTPUT_DIR}/freebox.key"

# ── Écrire la config Freebox (à importer dans Freebox OS) ─────────────────────
cat > "${OUTPUT_DIR}/freebox-wg1.conf" <<EOF
[Interface]
Address    = 10.200.0.2/32
PrivateKey = ${FREEBOX_PRIVATE_KEY}
DNS        = 1.1.1.1

[Peer]
# worker-1 Scaleway — serveur WireGuard NAS tunnel (wg1)
PublicKey           = ${SERVER_WG1_PUBKEY}
Endpoint            = ${WORKER1_PUBLIC_IP}:51821
AllowedIPs          = 10.200.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 "${OUTPUT_DIR}/freebox-wg1.conf"

echo ""
echo "Config Freebox générée : ${OUTPUT_DIR}/freebox-wg1.conf"
echo "→ Configurer dans Freebox OS : Paramètres avancés > VPN > WireGuard (client)"
echo ""
echo "┌─ Clé publique de la Freebox ───────────────────────────────────────────────┐"
echo "│  ${FREEBOX_PUBLIC_KEY}"
echo "└────────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "Étape suivante — ajouter la Freebox comme peer sur le worker-1 :"
echo ""
echo "  ansible-playbook ansible/playbooks/wireguard-nas.yml \\"
echo "    --vault-password-file ~/.ansible-vault-pass \\"
echo "    -e @ansible/group_vars/all.yml \\"
echo "    -e freebox_wg_pubkey=${FREEBOX_PUBLIC_KEY}"
echo ""
echo "Ou manuellement sur worker-1 :"
echo "  sudo wg set wg1 peer ${FREEBOX_PUBLIC_KEY} allowed-ips 10.200.0.2/32,192.168.1.0/24"
echo "  sudo wg-quick save wg1"
echo ""
echo "Puis vérifier la connectivité depuis worker-1 :"
echo "  ping 10.200.0.2         (IP WireGuard de la Freebox)"
echo "  ping 192.168.1.NAS_IP   (IP LAN du NAS — remplacer par la vraie IP)"
