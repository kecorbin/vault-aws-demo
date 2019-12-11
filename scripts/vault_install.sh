#!/bin/sh
# Configures the Vault server for a database secrets demo

echo "Preparing to install Vault..."
sudo apt-get -y update > /dev/null 2>&1
sudo apt-get -y upgrade > /dev/null 2>&1
sudo apt-get install -y unzip jq cowsay mysql-client > /dev/null 2>&1
sudo apt-get install -y python3 python3-pip
pip3 install awscli Flask mysql-connector-python hvac

mkdir /etc/vault.d
mkdir -p /opt/vault
mkdir -p /root/.aws

sudo bash -c "cat >/root/.aws/config" << 'EOF'
[default]
aws_access_key_id=${AWS_ACCESS_KEY}
aws_secret_access_key=${AWS_SECRET_KEY}
EOF
sudo bash -c "cat >/root/.aws/credentials" << 'EOF'
[default]
aws_access_key_id=${AWS_ACCESS_KEY}
aws_secret_access_key=${AWS_SECRET_KEY}
EOF

echo "Installing Vault..."
curl -sfLo "vault.zip" "${VAULT_URL}"
sudo unzip vault.zip -d /usr/local/bin/

# Server configuration
sudo bash -c "cat >/etc/vault.d/vault.hcl" << 'EOF'
storage "file" {
  path = "/opt/vault"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
EOF

# Set Vault up as a systemd service
echo "Installing systemd service for Vault..."
sudo bash -c "cat >/etc/systemd/system/vault.service" << 'EOF'
[Unit]
Description=Hashicorp Vault
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
Restart=on-failure # or always, on-abort, etc

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl start vault
sudo systemctl enable vault

sleep 5

export VAULT_IP=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`
export VAULT_ADDR=http://localhost:8200
# vault operator init -recovery-shares=1 -recovery-threshold=1 -key-shares=1 -key-threshold=1 > /root/init.txt 2>&1
vault operator init -recovery-shares=1 -recovery-threshold=1 > /root/init.txt 2>&1
export VAULT_TOKEN=`cat /root/init.txt | sed -n -e '/^Initial Root Token/ s/.*\: *//p'`
export DB_HOST=`echo '${MYSQL_HOST}' | awk -F ":" '/1/ {print $1}'`

sleep 5

vault write sys/license text=${VAULT_LICENSE}

# Setup demos
UNSEAL_KEY_1=`cat /root/init.txt | sed -n -e '/^Unseal Key 1/ s/.*\: *//p'`
UNSEAL_KEY_2=`cat /root/init.txt | sed -n -e '/^Unseal Key 2/ s/.*\: *//p'`
UNSEAL_KEY_3=`cat /root/init.txt | sed -n -e '/^Unseal Key 3/ s/.*\: *//p'`
mkdir /root/unseal
mkdir /root/database
mkdir /root/ec2auth
mkdir /root/eaas

# Auto unseal
sudo bash -c "cat >/root/unseal/s1_reconfig.sh" <<EOF
cat >>/etc/vault.d/vault.hcl <<VAULTCFG

seal "awskms" {
    region = "${AWS_REGION}"
    kms_key_id = "${AWS_KMS_KEY_ID}"
}
VAULTCFG
EOF
chmod a+x /root/unseal/s1_reconfig.sh

sudo bash -c "cat >/root/unseal/s2_unseal_migrate.sh" <<EOF
#!/bin/bash

vault operator unseal -migrate $UNSEAL_KEY_1
vault operator unseal -migrate $UNSEAL_KEY_2
vault operator unseal -migrate $UNSEAL_KEY_3
EOF
chmod a+x /root/unseal/s2_unseal_migrate.sh

sudo bash -c "cat >/root/unseal/s3_unseal_migrate.sh" <<EOF
#!/bin/bash

vault operator rekey -init -target=recovery -key-shares=1 -key-threshold=1
EOF
chmod a+x /root/unseal/s3_unseal_migrate.sh

sudo bash -c "cat >/root/unseal/s4_unseal_rekey.sh" <<EOF
#!/bin/bash
if [ -z "\$1" ]; then
  exit 1
fi
vault operator rekey -target=recovery -key-shares=1 -key-threshold=1 -nonce=\$1 $UNSEAL_KEY_1
vault operator rekey -target=recovery -key-shares=1 -key-threshold=1 -nonce=\$1 $UNSEAL_KEY_2
vault operator rekey -target=recovery -key-shares=1 -key-threshold=1 -nonce=\$1 $UNSEAL_KEY_3
EOF
chmod a+x /root/unseal/s4_unseal_rekey.sh

# Dynamic creds
sudo bash -c "cat >/root/database/s1_setup_db.sh" << 'EOF'
vault secrets enable database

vault write database/config/sedemovaultdb \
    plugin_name="mysql-database-plugin" \
    connection_url="{{username}}:{{password}}@tcp(${MYSQL_HOST})/" \
    allowed_roles="app-role" \
    username="${MYSQL_USER}" \
    password="${MYSQL_PASS}"

vault write database/roles/app-role \
    db_name=sedemovaultdb \
    creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';" \
    default_ttl="1h" \
    max_ttl="24h"

EOF
chmod a+x /root/database/s1_setup_db.sh

sudo bash -c "cat >/root/database/operators.hcl" << 'EOT'
path "database/roles/*" {
    capabilities = ["read", "list", "create", "delete", "update"]
}

path "database/creds/*" {
    capabilities = ["read", "list", "create", "delete", "update"]
}

path "secret/*" {
    capabilities = ["read", "list", "create", "delete", "update"]
}
EOT

sudo bash -c "cat >/root/database/appdevs.hcl" << 'EOT'
path "secret/*" {
    capabilities = ["read", "list"]
}
EOT

sudo bash -c "cat >/root/database/s2_policies.sh" << 'EOT'
vault policy write operators /root/database/operators.hcl
vault policy write appdevs /root/database/appdevs.hcl
EOT
chmod a+x /root/database/s2_policies.sh

sudo bash -c "cat >/root/database/s3_users.sh" << 'EOT'
vault auth enable userpass
vault write auth/userpass/users/james \
    password="superpass" \
    policies="operators"

vault write auth/userpass/users/sally \
    password="superpass" \
    policies="appdevs"
EOT
chmod a+x /root/database/s3_users.sh

# ec2 auth

sudo bash -c "cat >/root/ec2auth/s1_setup_auth.sh" << 'EOT'
vault auth enable aws

vault write auth/aws/config/client \
    secret_key=${AWS_SECRET_KEY} \
    access_key=${AWS_ACCESS_KEY}

vault policy write "db-policy" -<<EOF
path "database/creds/app-role" {
    capabilities = ["list", "read"]
}
EOF

vault write \
    auth/aws/role/app-db-role \
    auth_type=ec2 \
    policies=db-policy \
    max_ttl=1h \
    disallow_reauthentication=false \
    bound_ami_id=${AMI_ID}
EOT
chmod a+x /root/ec2auth/s1_setup_auth.sh

# encryption as a service
cd /root/eaas
git clone https://github.com/norhe/transit-app-example.git

sudo bash -c "cat >/root/eaas/s1_enable_transit.sh" <<EOT
# Enable Logging
vault audit enable file file_path=/var/log/vault_audit.log

# Enable the secret engine
vault secrets enable -path=lob_a/workshop/transit transit

# Create our customer key
vault write -f lob_a/workshop/transit/keys/customer-key

# Create our archive key to demonstrate multiple keys
vault write -f lob_a/workshop/transit/keys/archive-key
EOT
chmod a+x /root/eaas/s1_enable_transit.sh

sudo bash -c "cat >/root/eaas/transit-app-example/backend/config.ini" <<EOT
[DEFAULT]
LogLevel = WARN

[DATABASE]
Address=$DB_HOST
Port=3306
User=${MYSQL_USER}
Password=${MYSQL_PASS}
Database=my_app

[VAULT]
Enabled=False
DynamicDBCreds=False
ProtectRecords=False
Address=http://localhost:8200
Token=$VAULT_TOKEN
KeyPath=lob_a/workshop/transit
KeyName=customer-key
EOT

mkdir /root/eaas/app
mv /root/eaas/transit-app-example/backend/* /root/eaas/app
rm -r /root/eaas/transit-app-example

sudo bash -c "cat >/root/eaas/app/run" <<EOT
#!/bin/bash

python3 app.py
EOT
chmod a+x /root/eaas/app/run

# echo "Setting up environment variables..."
echo "export VAULT_ADDR=http://localhost:8200" >> /home/ubuntu/.profile
echo "export VAULT_TOKEN=$VAULT_TOKEN" >> /home/ubuntu/.profile
echo "export VAULT_ADDR=http://localhost:8200" >> /root/.profile
echo "export VAULT_TOKEN=$VAULT_TOKEN" >> /root/.profile

vault operator unseal $UNSEAL_KEY_1
vault operator unseal $UNSEAL_KEY_2
vault operator unseal $UNSEAL_KEY_3
vault login $VAULT_TOKEN
vault secrets enable -path="secret" -version=2 kv

# Add our AWS secrets
curl \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data '{"data": { "aws_access_key": "${AWS_ACCESS_KEY}", "aws_secret_key": "${AWS_SECRET_KEY}" } }' \
    http://127.0.0.1:8200/v1/secret/data/aws

curl \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data '{"data": { "username": "vault_user", "password": "Super$ecret1" } }' \
    http://127.0.0.1:8200/v1/secret/data/creds

echo "Vault installation complete."
