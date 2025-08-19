#!/bin/bash
#===================================================================
#Automated Multi-tier Web App Deployment on AWS EC2
#Web(Nginx)- App(Node.js)-DB(Maria DB)
#Author: saeed
#
#=======you edit these or pass env vars before running==============
REGION="${REGION:-ap-south-1}"          #eg ap-south-1
KEY_NAME="${KEY_NAME:-three-tier-demo-key}"
TAG_PREFIX="${TAG_PREFIX:-three-tier-demo}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"  #free tier eligible in many region 
#public Github repos (can be fork). if blank app will use inline sample
GIT_BACKEND="${GIT_BACKEND:-https://github.com/heroku/node-js-getting-started.git}"
GIT_FRONTEND="${GIT_FRONTEND:-https://github.com/mdn/beginner-html-site-styled.git}"
APP_VERSION="${APP_VERSION:-main}"  # branch/tag/commit for backend
# DB credentials (for demo; change in real setups!)
DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-appuser}"
DB_PASS="${DB_PASS:-apppass123}"
#========================================================================



set -euo pipefail

say() {
    echo -e "\n[INFO] $1\n"
}

err() {
    echo -e "\n[ERROR] $1\n" >&2
}

need() {
    command -v "$1" >/dev/null 2>&1 || {
        err "Missing $1. Install it and retry."
        exit 1
    }
}


# ---- Step 0: Pre-flight checks
say "Step 0: Pre-flight checks (aws, jq, region access)..."

need aws
need jq

aws sts get-caller-identity >/dev/null || { 
    err "AWS CLI not authenticated. Run: aws configure"
    exit 1
}

aws ec2 describe-availability-zones --region "$REGION" >/dev/null || { 
    err "Invalid/unauthorized region: $REGION"
    exit 1
}
# ---- Step 1: Get latest Ubuntu 22.04 AMI ID via SSM (portable across regions)
say "Step 1: Fetching latest Ubuntu 22.04 LTS AMI ID via SSM..."
AMI_PARAM="/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
AMI_ID=$(aws ssm get-parameters \
    --region "$REGION" \
    --names "$AMI_PARAM" \
    --query "Parameters[0].Value" \
    --output text)
echo "Using AMI: $AMI_ID"

# ---- Step 2: Create a key pair (for SSH); saved locally
say "Step 2: Creating key pair: $KEY_NAME (if not exists)..."

if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "Key pair $KEY_NAME already exists in AWS."
else
    aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
        --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
    echo "Saved private key: $(pwd)/${KEY_NAME}.pem"
fi


# ---- Step 3: Create Security Groups (Web, App, DB)
say " step 3 creating security groups (Web, App, DB) in default VPC..."

DEFAULT_VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)
[ "$DEFAULT_VPC_ID" = "None" ] && { 
  err "No default VPC in $REGION. Create a VPC or switch region."; 
  exit 1; 
}
# Create Security Groups
WEB_SG_ID=$(
  aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "${TAG_PREFIX}-web-sg" \
    --description "Web tier SG" \
    --vpc-id "$DEFAULT_VPC_ID" \
    --query "GroupId" \
    --output text
)
APP_SG_ID=$(
  aws ec2 create-security-group \
    --vpc-id "$DEFAULT_VPC_ID" \
    --query "GroupId" \
    --output text
)

DB_SG_ID=$(
  aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "${TAG_PREFIX}-db-sg" \
    --description "DB tier SG" \
    --vpc-id "$DEFAULT_VPC_ID" \
    --query "GroupId" \
    --output text
)

echo "Web SG : $WEB_SG_ID"
echo "App SG : $APP_SG_ID"
echo "DB  SG : $DB_SG_ID"

# Ingress rules:
# - Web: allow HTTP 80 from internet, SSH 22 (demo) from anywhere (tighten to your IP)------
echo "Adding inbound rules..."

# Allow HTTP traffic to Web SG from anywhere
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$WEB_SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="HTTP"}]'

# Allow SSH to Web SG from anywhere (demo purpose, tighten later)
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$WEB_SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description="SSH demo - tighten later"}]'

# Allow App SG to accept port 3000 traffic from Web SG
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$APP_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=$WEB_SG_ID,Description=\"From Web tier\"}]"

# Allow SSH to App SG from anywhere (demo purpose, tighten later)
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$APP_SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description="SSH demo - tighten later"}]'

# Allow DB SG to accept MySQL traffic from App SG
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$DB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$APP_SG_ID,Description=\"From App tier\"}]"

# ---- Step 4: Write user-data scripts (cloud-init) for each tier ------
# Create a user-data script for the DB tier
cat > user-data-db.sh <<'DBUD'
#!/bin/bash
set -e  # Exit immediately if a command fails

echo "[DB] Updating packages..."
apt-get update -y

echo "[DB] Installing MariaDB..."
DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server

echo "[DB] Configuring MariaDB to listen on all interfaces..."
sed -i "s/^bind-address.*/bind-address = 0.0.0.0/" /etc/mysql/mariadb.conf.d/50-server.cnf || true

# Enable and start MariaDB service
systemctl enable mariadb
systemctl start mariadb

echo "[DB] Securing root user and creating app DB/user..."
mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY 'ROOTPASS_PLACEHOLDER';
FLUSH PRIVILEGES;

CREATE DATABASE IF NOT EXISTS DBNAME_PLACEHOLDER;
CREATE USER IF NOT EXISTS 'DBUSER_PLACEHOLDER'@'%' IDENTIFIED BY 'DBPASS_PLACEHOLDER';
GRANT ALL PRIVILEGES ON DBNAME_PLACEHOLDER.* TO 'DBUSER_PLACEHOLDER'@'%';
FLUSH PRIVILEGES;
SQL

# Restart MariaDB to apply changes
systemctl restart mariadb

echo "[DB] Done."
DBUD

# App user-data: install Node.js, clone backend repo, create systemd service, start on boot ------
cat > user-data-app.sh <<'APPUD'
#!/bin/bash
set -e

echo "[APP] Updating packages..."
apt-get update -y

echo "[APP] Installing git, curl..."
apt-get install -y git curl

echo "[APP] Installing Node.js LTS..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# Create app directory
mkdir -p /opt/app && cd /opt/app

echo "[APP] Cloning backend repository..."
git clone GIT_BACKEND_PLACEHOLDER src
cd src
git checkout APP_VERSION_PLACEHOLDER || true

echo "[APP] Installing dependencies..."
npm install --omit=dev || npm install

# Create .env file for DB settings
cat > /opt/app/src/.env <<ENV
DB_HOST=DB_HOST_PLACEHOLDER
DB_NAME=DBNAME_PLACEHOLDER
DB_USER=DBUSER_PLACEHOLDER
DB_PASS=DBPASS_PLACEHOLDER
PORT=3000
ENV

# If sample app lacks server.js or app.js, create minimal Express API
if [ ! -f server.js ] && [ ! -f app.js ]; then
  echo "[APP] Creating minimal Express API..."
  cat > server.js <<'JS'
const express = require('express');
const app = express();
const port = process.env.PORT || 3000;

app.get('/api/health', (req, res) => res.json({ status: 'ok' }));

app.listen(port, () => console.log(`API listening on ${port}`));
JS

  echo '{}' > package.json
  npm install express
fi

# Create systemd service for Node.js app
cat > /etc/systemd/system/app.service <<'UNIT'
[Unit]
Description=Node.js App Service
After=network.target

[Service]
EnvironmentFile=/opt/app/src/.env
WorkingDirectory=/opt/app/src
ExecStart=/usr/bin/node server.js
Restart=on-failure
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

# Set permissions
chown -R ubuntu:ubuntu /opt/app

# Enable and start service
systemctl daemon-reload
systemctl enable app
systemctl start app

echo "[APP] Done."
APPUD
# Web user-data: install Nginx, pull static site, proxy /api to App private IP====
cat > user-data-web.sh <<'WEBUD'
#!/bin/bash
set -e

echo "[WEB] Updating packages..."
apt-get update -y

echo "[WEB] Installing git, nginx..."
apt-get install -y git nginx
systemctl enable nginx

# Create site directory and move into it
mkdir -p /var/www/html/site && cd /var/www/html/site

echo "[WEB] Cloning frontend repository..."
git clone GIT_FRONTEND_PLACEHOLDER . || true

# If no frontend repo found, create a simple HTML page
if [ ! -f index.html ]; then
  echo "<h1>Frontend</h1><p>Sample page</p><p><a href='/api/health'>Check API</a></p>" > index.html
fi

# Configure Nginx with reverse proxy for /api -> APP_PRIVATE_IP:3000
cat > /etc/nginx/sites-available/default <<NGINX
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html/site;

    location / {
        try_files \$uri \$uri/ =404;
        index index.html index.htm;
    }

    location /api/ {
        proxy_pass http://APP_PRIVATE_IP_PLACEHOLDER:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX

systemctl restart nginx
echo "[WEB] Done."
WEBUD
# Replace placeholders in DB user-data
sed -i "s/ROOTPASS_PLACEHOLDER/$DB_PASS/g" user-data-db.sh
sed -i "s/DBNAME_PLACEHOLDER/$DB_NAME/g" user-data-db.sh
sed -i "s/DBUSER_PLACEHOLDER/$DB_USER/g" user-data-db.sh
sed -i "s/DBPASS_PLACEHOLDER/$DB_PASS/g" user-data-db.sh


# ---- Step 5: Launch DB instance first (we need its private IP for App)-------
say "Step 5: Launching DB instance..."
DB_INSTANCE_JSON=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$DB_SG_ID" \
  --user-data "file://user-data-db.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_PREFIX}-db}]" \
  --query "Instances[0]" --output json)

DB_INSTANCE_ID=$(echo "$DB_INSTANCE_JSON" | jq -r .InstanceId)
say "DB Instance ID: $DB_INSTANCE_ID"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$DB_INSTANCE_ID"
DB_PRIVATE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$DB_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
echo "DB Private IP: $DB_PRIVATE_IP"
# Inject DB host + repo/version into APP user-data
sed -i "s|GIT_BACKEND_PLACEHOLDER|$GIT_BACKEND|g" user-data-app.sh
sed -i "s|APP_VERSION_PLACEHOLDER|$APP_VERSION|g" user-data-app.sh
sed -i "s|DB_HOST_PLACEHOLDER|$DB_PRIVATE_IP|g" user-data-app.sh
sed -i "s|DBNAME_PLACEHOLDER|$DB_NAME|g" user-data-app.sh
sed -i "s|DBUSER_PLACEHOLDER|$DB_USER|g" user-data-app.sh
sed -i "s|DBPASS_PLACEHOLDER|$DB_PASS|g" user-data-app.sh


# ---- Step 6: Launch App instance===
# Step 6: Launching App instance...
say "Step 6: Launching App instance..."

# EC2 instance launch for Application layer
APP_INSTANCE_JSON=$(aws ec2 run-instances \
  --region "$REGION" \                                # AWS region
  --image-id "$AMI_ID" \                              # AMI ID for OS image
  --instance-type "$INSTANCE_TYPE" \                  # EC2 instance size (e.g., t2.micro)
  --key-name "$KEY_NAME" \                            # SSH key pair
  --security-group-ids "$APP_SG_ID" \                  # Security Group ID for App server
  --user-data "file://user-data-app.sh" \              # App server ka startup script
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_PREFIX}-app}]" \  # Tagging instance
  --query "Instances[0]" --output json)                # JSON format output

# Instance ID extract out
APP_INSTANCE_ID=$(echo "$APP_INSTANCE_JSON" | jq -r .InstanceId)
say "App Instance ID: $APP_INSTANCE_ID"

# Wait until instance become in  running state 
aws ec2 wait instance-running --region "$REGION" --instance-ids "$APP_INSTANCE_ID"

# getting Private IP  
APP_PRIVATE_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$APP_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

# getting Public IP 
APP_PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$APP_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

# IPs print
echo "App Private IP: $APP_PRIVATE_IP"
echo "App Public  IP: $APP_PUBLIC_IP"
# Inject App private IP + frontend repo into WEB user-data
sed -i "s|APP_PRIVATE_IP_PLACEHOLDER|$APP_PRIVATE_IP|g" user-data-web.sh
sed -i "s|GIT_FRONTEND_PLACEHOLDER|$GIT_FRONTEND|g" user-data-web.sh




# ---- Step 7: Launch Web instance -----
# Step 7: Launching Web instance...
say "Step 7: Launching Web instance..."

# Web server ke liye EC2 instance launch karna
WEB_INSTANCE_JSON=$(aws ec2 run-instances \
  --region "$REGION" \                                # AWS region
  --image-id "$AMI_ID" \                              # OS image ka AMI ID
  --instance-type "$INSTANCE_TYPE" \                  # EC2 instance type (e.g., t2.micro)
  --key-name "$KEY_NAME" \                            # SSH key pair ka naam
  --security-group-ids "$WEB_SG_ID" \                  # Security Group for Web server
  --user-data "file://user-data-web.sh" \              # Boot time pe run hone wala script
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_PREFIX}-web}]" \  # Instance tagging
  --query "Instances[0]" --output json)                # Output JSON format me

# Instance ID extract out
WEB_INSTANCE_ID=$(echo "$WEB_INSTANCE_JSON" | jq -r .InstanceId)
say "Web Instance ID: $WEB_INSTANCE_ID"

# Wait until instance is running
aws ec2 wait instance-running --region "$REGION" --instance-ids "$WEB_INSTANCE_ID"

# getting Public IP address 
WEB_PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$WEB_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

# Public IP print 
echo "Web Public IP: $WEB_PUBLIC_IP"



# ---- Step 8: Output summary + basic health checks
say "Step 8: Deployment Summary"
cat <<OUT
==========================================
3-TIER APP DEPLOYED
------------------------------------------
Region:        $REGION
AMI:           $AMI_ID
Key Pair:      $KEY_NAME  (local file: ${KEY_NAME}.pem)

Security Groups:
  Web SG: $WEB_SG_ID
  App SG: $APP_SG_ID
  DB  SG: $DB_SG_ID

Instances:
  DB : $DB_INSTANCE_ID  (private: $DB_PRIVATE_IP)
  APP: $APP_INSTANCE_ID (private: $APP_PRIVATE_IP, public: $APP_PUBLIC_IP)
  WEB: $WEB_INSTANCE_ID (public:  $WEB_PUBLIC_IP)

Frontend URL:
  http://$WEB_PUBLIC_IP/

API health (via WEB reverse proxy):
  http://$WEB_PUBLIC_IP/api/health

(If 502 initially, wait 30-60 sec for app to finish installing.)

Tighten security later:
- Lock SSH (22) to your IP only, not 0.0.0.0/0.
- Consider private subnets + NAT for App/DB in next iteration.

To destroy all (see command after this output).
==========================================
OUT

say "ALL DONE ✅"   
