#!/bin/bash

#Install AWS_CLI
sudo apt-get update
sudo apt-get install -y awscli jq

sudo mkdir /opt/tfe

#copy license file from S3
aws s3 cp s3://${bucket_name}/license.rli /tmp/license.rli
aws s3 cp s3://${bucket_name}/certificate_pem /tmp/certificate_pem
aws s3 cp s3://${bucket_name}/issuer_pem /tmp/issuer_pem
aws s3 cp s3://${bucket_name}/private_key_pem /tmp/server.key

# Create a full chain from the certificates
cat /tmp/certificate_pem >> /tmp/server.crt
cat /tmp/issuer_pem >> /tmp/server.crt

PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)

cat > /tmp/tfe_settings.json <<EOF
{
    "enc_password": {
        "value": "${tfe-pwd}"
    },
    "hairpin_addressing": {
        "value": "0"
    },
    "hostname": {
        "value": "${dns_hostname}.${dns_zonename}"
    },
    "production_type": {
        "value": "disk"
    },
    "disk_path": {
        "value": "/opt/tfe"
    }
}
EOF

json=/tmp/tfe_settings.json

jq -r . $json
if [ $? -ne 0 ] ; then
    echo ERR: $json is not a valid json
    exit 1
fi

# create replicated unattended installer config
cat > /etc/replicated.conf <<EOF
{
  "DaemonAuthenticationType": "password",
  "DaemonAuthenticationPassword": "${tfe-pwd}",
  "TlsBootstrapType": "server-path",
  "TlsBootstrapHostname": "${dns_hostname}.${dns_zonename}",
  "TlsBootstrapCert": "/tmp/server.crt",
  "TlsBootstrapKey": "/tmp/server.key",
  "LogLevel": "debug",
  "ImportSettingsFrom": "/tmp/tfe_settings.json",
  "LicenseFileLocation": "/tmp/license.rli",
  "BypassPreflightChecks": true
}
EOF

json=/etc/replicated.conf
jq -r . $json
if [ $? -ne 0 ] ; then
    echo ERR: $json is not a valid json
    exit 1
fi

# iact configuration
cat > /tmp/iact.sh <<EOF
#!/bin/bash

status=\$(replicatedctl app status --template '{{.State}}')

while [[ \$status != *"started"* ]]; do
  echo "Application status: \$status"
  sleep 10
  status=\$(replicatedctl app status --template '{{.State}}')
done

sleep 60

# get the admin token you can use to create the first user
ADMIN_TOKEN=\`sudo /usr/local/bin/replicated admin --tty=0 retrieve-iact | tr -d '\r'\`

# Create the first user called admin and get the token
TOKEN=\`curl --header "Content-Type: application/json" --request POST --data '{"username": "admin", "email": "${certificate_email}", "password": "${tfe-pwd}"}' \ --url https://${dns_hostname}.${dns_zonename}/admin/initial-admin-user?token=\$ADMIN_TOKEN | jq '.token' | tr -d '"'\`

# create the organization called test
curl \
  --header "Authorization: Bearer \$TOKEN" \
  --header "Content-Type: application/vnd.api+json" \
  --request POST \
  --data '{"data": { "type": "organizations", "attributes": {"name": "test", "email": "${certificate_email}"}}}' \
  https://${dns_hostname}.${dns_zonename}/api/v2/organizations

# Create a workspace named test-workspace
curl \
  --header "Authorization: Bearer \$TOKEN" \
  --header "Content-Type: application/vnd.api+json" \
  --request POST \
  --data '{"data": {"attributes": {"name": "test-workspace", "resource-count": 0, "updated-at": "2017-11-29T19:18:09.976Z"}, "type": "workspaces"}}' \
  https://${dns_hostname}.${dns_zonename}/api/v2/organizations/test/workspaces
EOF

# install replicated
curl -Ls -o /tmp/install.sh https://install.terraform.io/ptfe/stable
sudo bash /tmp/install.sh \
        release-sequence=${tfe_release_sequence} \
        no-proxy \
        private-address=$PRIVATE_IP \
        public-address=$PUBLIC_IP



# run iact script
chmod +x /tmp/iact.sh
sudo bash /tmp/iact.sh