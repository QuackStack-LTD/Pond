#!/usr/bin/env bash

set -euo pipefail

echo "[1] Detecting IP..."
MANAGER_IP=$(hostname -I | awk '{print $1}')
echo "Manager IP: $MANAGER_IP"

WORKDIR=~/docker-tls
DOCKER_TLS_DIR=/etc/docker/tls

echo "[2] Preparing directories..."
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ========================
# CA
# ========================
echo "[3] Generating CA..."
openssl genrsa -out ca-key.pem 4096

openssl req -x509 -new -nodes \
  -key ca-key.pem \
  -sha256 -days 3650 \
  -out ca.pem \
  -subj "/CN=docker-ca"

# ========================
# SERVER CERT
# ========================
echo "[4] Generating server cert..."
openssl genrsa -out server-key.pem 4096

openssl req -new -key server-key.pem -out server.csr \
  -subj "/CN=$MANAGER_IP"

cat > extfile.cnf <<EOF
subjectAltName = IP:$MANAGER_IP
extendedKeyUsage = serverAuth
EOF

openssl x509 -req -in server.csr \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -out server-cert.pem \
  -days 3650 -sha256 \
  -extfile extfile.cnf

# ========================
# CLIENT CERT
# ========================
echo "[5] Generating client cert..."
openssl genrsa -out key.pem 4096

openssl req -new -key key.pem -out client.csr \
  -subj "/CN=github-actions"

echo "extendedKeyUsage = clientAuth" > extfile-client.cnf

openssl x509 -req -in client.csr \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -out cert.pem \
  -days 3650 -sha256 \
  -extfile extfile-client.cnf

# ========================
# DOCKER TLS FILES
# ========================
echo "[6] Installing TLS certs..."
sudo mkdir -p "$DOCKER_TLS_DIR"

sudo cp ca.pem "$DOCKER_TLS_DIR/ca.pem"
sudo cp server-cert.pem "$DOCKER_TLS_DIR/server-cert.pem"
sudo cp server-key.pem "$DOCKER_TLS_DIR/server-key.pem"

sudo chown root:root "$DOCKER_TLS_DIR"/*
sudo chmod 600 "$DOCKER_TLS_DIR/server-key.pem"
sudo chmod 644 "$DOCKER_TLS_DIR/ca.pem" "$DOCKER_TLS_DIR/server-cert.pem"

# ========================
# DOCKER DAEMON CONFIG
# ========================
echo "[7] Writing daemon.json..."

sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2376"],
  "tls": true,
  "tlsverify": true,
  "tlscacert": "$DOCKER_TLS_DIR/ca.pem",
  "tlscert": "$DOCKER_TLS_DIR/server-cert.pem",
  "tlskey": "$DOCKER_TLS_DIR/server-key.pem"
}
EOF

# ========================
# FIX SYSTEMD CONFLICT (CRITICAL)
# ========================
echo "[8] Fixing systemd docker service..."

sudo mkdir -p /etc/systemd/system/docker.service.d

sudo tee /etc/systemd/system/docker.service.d/override.conf > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload

# ========================
# RESTART DOCKER
# ========================
echo "[9] Restarting Docker..."
sudo systemctl restart docker

# quick sanity
sleep 2
docker info > /dev/null

# ========================
# FIREWALL
# ========================
echo "[10] Opening port 2376..."
sudo ufw allow 2376/tcp || true

# ========================
# SWARM INIT
# ========================
echo "[11] Initializing Swarm..."
docker swarm init --advertise-addr "$MANAGER_IP" || true

# ========================
# OUTPUT SECRETS
# ========================
echo ""
echo "================ GITHUB SECRETS ================"
echo ""
echo "SWARM_MANAGER_IP:"
echo "$MANAGER_IP"
echo ""

echo "SWARM_CA_PEM:"
cat ca.pem
echo ""

echo "SWARM_CLIENT_CERT_PEM:"
cat cert.pem
echo ""

echo "SWARM_CLIENT_KEY_PEM:"
cat key.pem
echo ""

echo "==============================================="
echo ""
echo "Done."
