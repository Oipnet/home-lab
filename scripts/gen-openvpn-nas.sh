#!/usr/bin/env bash
# gen-openvpn-nas.sh — Génère les certificats OpenVPN et le fichier client pour le NAS.
# À lancer une seule fois depuis la racine du dépôt.
# Prérequis : openssl, WORKER1_PUBLIC_IP défini dans .env ou l'environnement.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI_DIR="$REPO_ROOT/openvpn/pki"
NAS_DIR="$REPO_ROOT/openvpn/nas"

mkdir -p "$PKI_DIR" "$NAS_DIR"

# ── Charger .env si présent ───────────────────────────────────────────────────
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a && source "$REPO_ROOT/.env" && set +a
fi

WORKER1_IP="${WORKER1_PUBLIC_IP:-}"
if [[ -z "$WORKER1_IP" ]]; then
  echo "[ERROR] WORKER1_PUBLIC_IP non défini. Renseigner dans .env ou exporter la variable."
  exit 1
fi

OPENVPN_PORT="${OPENVPN_NAS_PORT:-1194}"

# ── Génération des certificats ────────────────────────────────────────────────
if [[ -f "$PKI_DIR/ca.crt" && -f "$PKI_DIR/server.crt" && -f "$PKI_DIR/nas.crt" ]]; then
  echo "[INFO] Certificats déjà présents dans $PKI_DIR — génération ignorée."
  echo "[INFO] Supprimer $PKI_DIR pour régénérer."
else
  echo "[INFO] Génération du CA..."
  openssl genrsa -out "$PKI_DIR/ca.key" 2048 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$PKI_DIR/ca.key" \
    -out "$PKI_DIR/ca.crt" -subj "/CN=homelab-vpn-ca" 2>/dev/null

  echo "[INFO] Génération du certificat serveur..."
  openssl genrsa -out "$PKI_DIR/server.key" 2048 2>/dev/null
  openssl req -new -key "$PKI_DIR/server.key" \
    -out "$PKI_DIR/server.csr" -subj "/CN=homelab-vpn-server" 2>/dev/null

  cat > /tmp/openvpn_server_ext.cnf << 'EXTEOF'
[server_ext]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EXTEOF

  openssl x509 -req -days 3650 -in "$PKI_DIR/server.csr" \
    -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -out "$PKI_DIR/server.crt" \
    -extfile /tmp/openvpn_server_ext.cnf -extensions server_ext 2>/dev/null

  echo "[INFO] Génération du certificat client NAS..."
  openssl genrsa -out "$PKI_DIR/nas.key" 2048 2>/dev/null
  openssl req -new -key "$PKI_DIR/nas.key" \
    -out "$PKI_DIR/nas.csr" -subj "/CN=nas" 2>/dev/null

  cat > /tmp/openvpn_client_ext.cnf << 'EXTEOF'
[client_ext]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EXTEOF

  openssl x509 -req -days 3650 -in "$PKI_DIR/nas.csr" \
    -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -out "$PKI_DIR/nas.crt" \
    -extfile /tmp/openvpn_client_ext.cnf -extensions client_ext 2>/dev/null

  echo "[INFO] Génération des paramètres DH 2048-bit (~30s)..."
  openssl dhparam -out "$PKI_DIR/dh.pem" 2048 2>/dev/null

  chmod 600 "$PKI_DIR"/*.key
  echo "[INFO] Certificats générés."
fi

# ── Génération du fichier nas.ovpn ────────────────────────────────────────────
echo "[INFO] Génération de nas.ovpn..."
cat > "$NAS_DIR/nas.ovpn" << EOF
client
dev tun
proto udp
remote ${WORKER1_IP} ${OPENVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
keepalive 10 60
verb 3

<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>

<cert>
$(openssl x509 -in "$PKI_DIR/nas.crt" 2>/dev/null)
</cert>

<key>
$(cat "$PKI_DIR/nas.key")
</key>
EOF
chmod 600 "$NAS_DIR/nas.ovpn"

echo ""
echo "[OK] Fichiers générés :"
echo "     PKI        : $PKI_DIR/"
echo "     NAS config : $NAS_DIR/nas.ovpn"
echo ""
echo "Étapes suivantes :"
echo "  1. ./scripts/init-cluster.sh openvpn-nas"
echo "     (installe et configure OpenVPN sur worker-1)"
echo "  2. Importer $NAS_DIR/nas.ovpn dans DSM :"
echo "     Panneau de configuration > Réseau > Interface réseau > Créer > Profil VPN > OpenVPN"
echo "  3. Vérifier que le NAS a bien obtenu l'IP 10.200.0.2"
echo "  4. Vérifier l'accès NFS depuis worker-1 : showmount -e 10.200.0.2"
