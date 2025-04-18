Node 20
```bash
# Create directory for user-local packages
mkdir -p ~/.npm-global

# Configure npm to use the new directory path
npm config set prefix '~/.npm-global'

# Add npm path to .bashrc
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc

# Apply the changes without logging out and back in
export PATH=~/.npm-global/bin:$PATH

# Install Node.js 20 using nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

# Source nvm without closing the terminal
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Install Node.js 20
nvm install 20

# Verify installation
node -v
npm -v
```
Claude
```bash
# Install Claude Code (after Node.js is installed)
npm install -g @anthropic-ai/claude-code
# Create Claude Code config directory
mkdir -p ~/.config/claude-code
# Verify Claude Code installation
which claude
```
Check
```bas
# Check system and swap configuration
uname -a
free -h
swapon --show

# Check Docker installation
docker --version
systemctl status docker
docker-compose --version

# Check the custom bash prompt and aliases
grep "force_color_prompt=yes" ~/.bashrc
grep "@ \\\\e\[32;40m\\\\u\\\\e\[m" ~/.bashrc
cat ~/.bash_aliases

# Check if Secret Manager access is working
gcloud --version
curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token

gcloud secrets list --project=scripthammer

# Check if boot script completed
ls -la /tmp/server-boot-completed

# Check if Node.js is installed (if you've run the user installation)
node -v
npm -v
which node

# Check if Claude Code is installed (if you've run the user installation)
which claude
```

# WordPress with BuddyPress: Deployment Guide

This guide covers the practical steps to deploy the WordPress environment with BuddyPress, GamiPress, and Allyship Curriculum, starting with a fresh server.

## 1. SSH Key Setup for GitHub Access

When starting with a fresh server, first set up SSH access to GitHub:

```bash
# Generate a new SSH key (use your actual email)
ssh-keygen -t ed25519 -C "your_email@example.com"

# Start the SSH agent in the background
eval "$(ssh-agent -s)"

# Add your SSH key to the agent (skip passphrase by pressing enter)
ssh-add ~/.ssh/id_ed25519

# Copy the public key to add to your GitHub account
cat ~/.ssh/id_ed25519.pub
```

Then:
1. Go to GitHub → Settings → SSH and GPG keys
2. Click "New SSH key" 
3. Paste your key and save

Test the connection:
```bash
# Verify GitHub access
ssh -T git@github.com
```

## 2. Clone the Repository

```bash
# Clone using SSH (not HTTPS) to avoid authentication issues
git clone git@github.com:TortoiseWolfe/wp-dev.git
cd wp-dev

# Make all scripts executable
chmod +x scripts/*.sh scripts/*/*.sh devscripts/*.sh
```

## 3. Set Up Environment

### Option A: Local Development Environment

```bash
# Generate secure local credentials
source ./scripts/dev/setup-local-dev.sh

# Start development containers
sudo -E docker-compose up -d wordpress wp-setup db
```

### Option B: Production Environment with Google Secret Manager

```bash#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Configuration — define the fixed GitHub token to hardcode below
################################################################################

# 👇 Replace with your actual token (keep it safe and don't commit!)
GITHUB_TOKEN="ghp_YourFixedTokenGoesHere"


################################################################################
# Delete & recreate the GITHUB_TOKEN secret
################################################################################

echo "⏳ Deleting existing secret: GITHUB_TOKEN (if it exists)…"
gcloud secrets delete GITHUB_TOKEN --quiet || true

echo "📦 Creating new secret: GITHUB_TOKEN…"
gcloud secrets create GITHUB_TOKEN --replication-policy="automatic"

echo -n "$GITHUB_TOKEN" \
  | gcloud secrets versions add GITHUB_TOKEN --data-file=-

echo "✅ GITHUB_TOKEN successfully reset and seeded."


################################################################################
# Export into current shell session (optional)
################################################################################

export GITHUB_TOKEN

echo
echo "🔐 GITHUB_TOKEN is now available in your current shell session."
```

## 4. GitHub Authentication Flow

```bash
# CRITICAL: Always follow this exact sequence:

# 1. First load secrets from Google Secret Manager
source ./scripts/setup-secrets.sh

# 2. Then authenticate with GitHub Container Registry
sudo -E docker login ghcr.io -u tortoisewolfe --password "$GITHUB_TOKEN"

# 3. Only then pull the image
sudo -E docker pull ghcr.io/tortoisewolfe/wp-dev:v0.1.1
```

## 5. Configure Domain and SSL

```bash
# Edit .env file to set your domain
nano .env
# Change: WP_SITE_URL=https://yourdomain.com
# Change: DOMAIN_NAME=yourdomain.com
# Change: CERTBOT_EMAIL=your@email.com

# Set up SSL certificates
sudo ./scripts/ssl/ssl-setup.sh
```

## 6. Deploy the Application

```bash
# Complete deployment sequence for production
source ./scripts/setup-secrets.sh
sudo -E docker login ghcr.io -u tortoisewolfe --password "$GITHUB_TOKEN"
sudo -E docker-compose up -d
```

## 7. Verify Installation

```bash
# Check container status
sudo docker-compose ps

# Verify WordPress installation
sudo -E docker-compose exec wordpress-prod wp core is-installed --allow-root

# Check BuddyPress status
sudo -E docker-compose exec wordpress-prod wp plugin status buddypress --allow-root
```

## 8. Common Issues and Solutions

### GitHub Authentication Errors

If you see `Error: Head: unauthorized` or similar:

```bash
# Always use this full sequence - order matters!
source ./scripts/setup-secrets.sh
sudo -E docker login ghcr.io -u tortoisewolfe --password "$GITHUB_TOKEN" 
sudo -E docker pull ghcr.io/tortoisewolfe/wp-dev:v0.1.1
```

### SSH Agent Issues

If you get SSH authentication errors when connecting to GitHub:

```bash
# Ensure SSH agent is running and has your key
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Verify GitHub can access your key
ssh -vT git@github.com
```

### WordPress Setup Issues

If WordPress setup fails:

```bash
# Check logs
sudo docker-compose logs wordpress-prod

# Verify database connection
sudo docker-compose exec wordpress-prod wp db check --allow-root

# Manually trigger setup
sudo docker-compose exec wordpress-prod /usr/local/bin/scripts/setup.sh
```

## Maintenance Tasks

### Backup Database and Files

```bash
# Database backup
sudo docker-compose exec db mysqldump -u root -p${MYSQL_ROOT_PASSWORD} wordpress > backup-$(date +%Y%m%d).sql

# Files backup
sudo docker-compose exec wordpress-prod tar -czf /tmp/wp-content-backup.tar.gz /var/www/html/wp-content
sudo docker cp $(sudo docker-compose ps -q wordpress-prod):/tmp/wp-content-backup.tar.gz ./wp-content-backup-$(date +%Y%m%d).tar.gz
```

### Update WordPress Core and Plugins

```bash
sudo docker-compose exec wordpress-prod wp core update --allow-root
sudo docker-compose exec wordpress-prod wp plugin update --all --allow-root
sudo docker-compose exec wordpress-prod wp theme update --all --allow-root
```

### SSL Certificate Renewal

Certificates are automatically renewed, but you can force renewal:

```bash
sudo docker-compose exec certbot certbot renew --force-renewal
sudo docker-compose restart nginx
```

This practical guide should more closely match your real-world experience deploying the application to a new server, starting with the essential SSH key setup for GitHub access.
