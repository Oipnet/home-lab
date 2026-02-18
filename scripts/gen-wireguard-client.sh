#!/usr/bin/env bash
# gen-wireguard-client.sh — Generate a WireGuard client config for Plex VPN access.
# Usage: ./scripts/gen-wireguard-client.sh <client-name> <vpn-ip-last-octet>
# Example: ./scripts/gen-wireguard-client.sh laptop 2
set -euo pipefail

# Charger .env si présent (SERVER_PUBLIC_IP et SERVER_WG0_PUBKEY)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "$SCRIPT_DIR/../.env" && set +a
fi

CLIENT_NAME="${1:?Usage: $0 <client-name> <vpn-ip-last-octet>}"
IP_OCTET="${2:?Usage: $0 <client-name> <vpn-ip-last-octet>}"
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:?Set SERVER_PUBLIC_IP env var}"
SERVER_WG0_PUBKEY="${SERVER_WG0_PUBKEY:?Set SERVER_WG0_PUBKEY env var}"

VPN_CLIENT_IP="10.201.0.${IP_OCTET}"
OUTPUT_DIR="wireguard/client-vpn/clients/${CLIENT_NAME}"
mkdir -p "$OUTPUT_DIR"

# Generate key pair
wg genkey | tee "${OUTPUT_DIR}/private.key" | wg pubkey > "${OUTPUT_DIR}/public.key"
chmod 600 "${OUTPUT_DIR}/private.key"

PRIVATE_KEY="$(cat "${OUTPUT_DIR}/private.key")"
PUBLIC_KEY="$(cat "${OUTPUT_DIR}/public.key")"

# Write client config
cat > "${OUTPUT_DIR}/wg0.conf" <<EOF
[Interface]
Address    = ${VPN_CLIENT_IP}/32
PrivateKey = ${PRIVATE_KEY}
DNS        = 1.1.1.1

[Peer]
PublicKey           = ${SERVER_WG0_PUBKEY}
Endpoint            = ${SERVER_PUBLIC_IP}:51820
AllowedIPs          = 10.201.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 "${OUTPUT_DIR}/wg0.conf"

echo "Client config written to: ${OUTPUT_DIR}/wg0.conf"
echo ""
echo "Add this [Peer] block to the SERVER's /etc/wireguard/wg0.conf:"
echo ""
echo "[Peer]"
echo "# ${CLIENT_NAME}"
echo "PublicKey  = ${PUBLIC_KEY}"
echo "AllowedIPs = ${VPN_CLIENT_IP}/32"
echo ""
echo "Then reload: sudo wg syncconf wg0 <(wg-quick strip wg1)"

# Generate QR code if qrencode is available
if command -v qrencode &>/dev/null; then
  echo ""
  echo "Scan this QR code with the WireGuard mobile app:"
  qrencode -t ansiutf8 < "${OUTPUT_DIR}/wg0.conf"
fi
