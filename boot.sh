#!/bin/bash
set -e

#region VARIABLES AND CONFIGURATION
####################################
### VARIABLES AND CONFIGURATION ###
####################################
# Define your variables here
LOG_FILE="/var/log/server-boot.log"
TIMEZONE="America/New_York"

# WordPress and Database Configuration
# Settings to be sourced from Secret Manager:
# - MYSQL_ROOT_PASSWORD
# - MYSQL_PASSWORD
# - WP_ADMIN_PASSWORD
# - WP_ADMIN_EMAIL
# - GITHUB_TOKEN

# Settings with defaults (not in Secret Manager):
WP_DB_NAME="wordpress"
WP_DB_USER="wordpress"
WP_SITE_TITLE="WordPress Site"
WP_ADMIN_USER="admin"
DEPLOY_DIR="/var/www/wp-dev"
#endregion

#region INITIALIZATION
######################
### INITIALIZATION ###
######################
# Initial setup and logging
echo "=== SERVER BOOT SCRIPT STARTING at $(date) ===" > $LOG_FILE
echo "Running as user: $(whoami)" >> $LOG_FILE
echo "Hostname: $(hostname)" >> $LOG_FILE
echo "Setting timezone to ${TIMEZONE}" >> $LOG_FILE
timedatectl set-timezone ${TIMEZONE}
#endregion

#region SECRET MANAGER ACCESS
############################
### SECRET MANAGER ACCESS ###
############################
echo "Setting up Secret Manager access" >> $LOG_FILE

# First, install gcloud CLI if not present
if ! command -v gcloud &> /dev/null; then
    echo "Installing Google Cloud SDK" >> $LOG_FILE
    apt-get update && apt-get install -y apt-transport-https ca-certificates gnupg curl
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
    apt-get update && apt-get install -y google-cloud-sdk
fi

# Critical: Use application default credentials and ensure cloud-platform scope
# This allows access even without explicit role assignment by using scopes
echo "Configuring VM authentication" >> $LOG_FILE

# Install jq if not present (needed for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo "Installing jq for JSON parsing" >> $LOG_FILE
    apt-get update && apt-get install -y jq
fi

# Secret retrieval function using direct API access via curl
get_secret() {
    local secret_name="$1"
    local project_id="${2:-scripthammer}"
    local version="${3:-latest}"
    
    echo "Retrieving secret: $secret_name using direct API access" >> $LOG_FILE
    
    # Get the access token from metadata server
    TOKEN=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)
    
    # API endpoint for secret access
    API_URL="https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/${secret_name}/versions/${version}:access"
    
    # Retrieve secret with proper auth
    RESPONSE=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${API_URL}")
    
    # Check if successful and extract the value
    if echo "$RESPONSE" | grep -q "payload"; then
        # Extract and decode the base64 payload
        SECRET_VALUE=$(echo "$RESPONSE" | jq -r .payload.data | base64 --decode)
        echo "Successfully retrieved secret: $secret_name" >> $LOG_FILE
        echo "$SECRET_VALUE"
    else
        echo "ERROR: Failed to retrieve secret: $secret_name" >> $LOG_FILE
        echo "ERROR_RETRIEVING_SECRET"
    fi
}

# Retrieve secrets
GITHUB_TOKEN=$(get_secret "GITHUB_TOKEN")
MYSQL_PASSWORD=$(get_secret "MYSQL_PASSWORD")
MYSQL_ROOT_PASSWORD=$(get_secret "MYSQL_ROOT_PASSWORD")
WP_ADMIN_EMAIL=$(get_secret "WP_ADMIN_EMAIL")
WP_ADMIN_PASSWORD=$(get_secret "WP_ADMIN_PASSWORD")

# Handle failures with fallbacks
for secret_var in "GITHUB_TOKEN" "MYSQL_PASSWORD" "MYSQL_ROOT_PASSWORD" "WP_ADMIN_EMAIL" "WP_ADMIN_PASSWORD"; do
    value=$(eval echo \${$secret_var})
    if [ "$value" = "ERROR_RETRIEVING_SECRET" ]; then
        echo "WARNING: Using fallback for $secret_var" >> $LOG_FILE
        # Set fallback values
        case "$secret_var" in
            "GITHUB_TOKEN") GITHUB_TOKEN="token_placeholder" ;;
            "MYSQL_PASSWORD") MYSQL_PASSWORD="default_mysql_password" ;;
            "MYSQL_ROOT_PASSWORD") MYSQL_ROOT_PASSWORD="default_mysql_root_password" ;;
            "WP_ADMIN_EMAIL") WP_ADMIN_EMAIL="admin@example.com" ;;
            "WP_ADMIN_PASSWORD") WP_ADMIN_PASSWORD="default_admin_password" ;;
        esac
    fi
done
#endregion

#region SYSTEM PREPARATION
##########################
### SYSTEM PREPARATION ###
##########################
# Function to wait for apt locks to be released with extended timeout
wait_for_apt() {
    echo "Checking for apt locks..." >> $LOG_FILE
    
    # Wait up to 30 minutes on first boot (common for cloud instances to run initial updates)
    for i in $(seq 1 180); do  # 180 tries * 10 seconds = 30 minutes
        if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || lsof /var/lib/apt/lists/lock >/dev/null 2>&1 || lsof /var/cache/apt/archives/lock >/dev/null 2>&1; then
            echo "Waiting for apt locks to be released (attempt $i/180)... waiting 10 seconds" >> $LOG_FILE
            sleep 10
        else
            echo "Apt locks released, proceeding..." >> $LOG_FILE
            return 0
        fi
    done
    
    echo "ERROR: Timed out waiting for apt locks after 30 minutes" >> $LOG_FILE
    echo "Checking which processes are holding the locks:" >> $LOG_FILE
    lsof /var/lib/dpkg/lock-frontend >> $LOG_FILE 2>&1 || true
    lsof /var/lib/apt/lists/lock >> $LOG_FILE 2>&1 || true
    lsof /var/cache/apt/archives/lock >> $LOG_FILE 2>&1 || true
    echo "Running package processes:" >> $LOG_FILE
    ps aux | grep -E 'apt|dpkg' | grep -v grep >> $LOG_FILE || true
    
    # Return failure but continue with script
    return 1
}

# Update packages with robust retry mechanism
echo "Updating package lists" >> $LOG_FILE

# Function to retry apt operations
retry_apt_operation() {
    local cmd="$1"
    local desc="$2"
    local max_attempts=5
    local wait_time=30
    
    echo "Starting $desc..." >> $LOG_FILE
    
    for attempt in $(seq 1 $max_attempts); do
        echo "Attempt $attempt/$max_attempts for $desc" >> $LOG_FILE
        
        # Wait for apt locks
        wait_for_apt || { 
            echo "WARNING: Could not acquire apt locks, but trying anyway" >> $LOG_FILE
        }
        
        # Run the command
        eval "$cmd" >> $LOG_FILE 2>&1
        
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            echo "SUCCESS: $desc completed on attempt $attempt" >> $LOG_FILE
            return 0
        else
            echo "ERROR: $desc failed with exit code $exit_code on attempt $attempt" >> $LOG_FILE
            
            if [ $attempt -lt $max_attempts ]; then
                echo "Waiting $wait_time seconds before next attempt..." >> $LOG_FILE
                sleep $wait_time
            else
                echo "FAILED: $desc failed after $max_attempts attempts" >> $LOG_FILE
            fi
        fi
    done
    
    return 1
}

# Update package lists with retries
retry_apt_operation "apt-get update -y" "package list update" || {
    echo "WARNING: Package update failed, will continue anyway" >> $LOG_FILE
}

# Install essential packages with retries
echo "Installing essential packages" >> $LOG_FILE
retry_apt_operation "apt-get -y install apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release" "essential packages installation" || {
    echo "WARNING: Essential package installation failed, will continue anyway" >> $LOG_FILE
    echo "Available packages:" >> $LOG_FILE
    apt-cache policy apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release >> $LOG_FILE 2>&1
}
#endregion

#region SWAP CONFIGURATION
##########################
### SWAP CONFIGURATION ###
##########################
# Create swap file
SWAP_SIZE=4
echo "Creating ${SWAP_SIZE}GB swap file" >> $LOG_FILE
if [ ! -f /swapfile ]; then
    fallocate -l ${SWAP_SIZE}G /swapfile >> $LOG_FILE 2>&1 || {
        echo "ERROR: fallocate failed with exit code $?" >> $LOG_FILE
        echo "Trying dd method instead" >> $LOG_FILE
        dd if=/dev/zero of=/swapfile bs=1G count=${SWAP_SIZE} >> $LOG_FILE 2>&1 || {
            echo "ERROR: dd swap creation failed with exit code $?" >> $LOG_FILE
            ls -la / >> $LOG_FILE
            df -h >> $LOG_FILE
        }
    }
    
    echo "Setting swap file permissions" >> $LOG_FILE
    chmod 600 /swapfile >> $LOG_FILE 2>&1 || echo "ERROR: chmod on swapfile failed with $?" >> $LOG_FILE
    
    echo "Setting up swap" >> $LOG_FILE
    mkswap /swapfile >> $LOG_FILE 2>&1 || echo "ERROR: mkswap failed with $?" >> $LOG_FILE
    swapon /swapfile >> $LOG_FILE 2>&1 || echo "ERROR: swapon failed with $?" >> $LOG_FILE
    
    echo "Adding swap to fstab" >> $LOG_FILE
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    sysctl -p >> $LOG_FILE 2>&1 || echo "ERROR: sysctl failed with $?" >> $LOG_FILE
    
    echo "Swap status:" >> $LOG_FILE
    swapon --show >> $LOG_FILE 2>&1
    free -h >> $LOG_FILE 2>&1
fi
#endregion

#region DOCKER INSTALLATION
###########################
### DOCKER INSTALLATION ###
###########################
# Install Docker
echo "Installing Docker" >> $LOG_FILE
if ! command -v docker &> /dev/null; then
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        echo "Detected OS: $OS" >> $LOG_FILE
    else
        OS="unknown"
        echo "Could not detect OS, defaulting to unknown" >> $LOG_FILE
    fi
    
    # Add Docker official GPG key
    echo "Adding Docker GPG key" >> $LOG_FILE
    curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>> $LOG_FILE || {
        echo "ERROR: Docker GPG key installation failed with exit code $?" >> $LOG_FILE
    }
    
    # Set up the stable repository based on OS
    echo "Setting up Docker repository for $OS" >> $LOG_FILE
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    echo "Updating package lists for Docker" >> $LOG_FILE
    wait_for_apt || { echo "ERROR: Could not acquire apt locks, continuing anyway" >> $LOG_FILE; }
    apt-get update >> $LOG_FILE 2>&1 || {
        echo "ERROR: apt-get update for Docker failed with exit code $?" >> $LOG_FILE
        cat /var/log/apt/term.log >> $LOG_FILE 2>/dev/null || echo "Could not read apt term log" >> $LOG_FILE
    }
    
    echo "Installing Docker packages" >> $LOG_FILE
    wait_for_apt || { echo "ERROR: Could not acquire apt locks, continuing anyway" >> $LOG_FILE; }
    
    # Try installing Docker with multiple attempts
    for attempt in {1..3}; do
        echo "Attempting to install Docker (attempt $attempt/3)" >> $LOG_FILE
        if apt-get -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin >> $LOG_FILE 2>&1; then
            echo "Docker installation succeeded on attempt $attempt" >> $LOG_FILE
            break
        else
            echo "ERROR: Docker installation failed with exit code $? on attempt $attempt" >> $LOG_FILE
            cat /var/log/apt/term.log >> $LOG_FILE 2>/dev/null || echo "Could not read apt term log" >> $LOG_FILE
            if [ $attempt -eq 3 ]; then
                echo "ERROR: Docker installation failed after 3 attempts" >> $LOG_FILE
            else
                echo "Waiting 30 seconds before next attempt..." >> $LOG_FILE
                sleep 30
                wait_for_apt || { echo "ERROR: Could not acquire apt locks, continuing anyway" >> $LOG_FILE; }
            fi
        fi
    done
    
    # Start and enable Docker
    echo "Starting and enabling Docker service" >> $LOG_FILE
    systemctl enable docker >> $LOG_FILE 2>&1 || echo "ERROR: Docker enable failed with $?" >> $LOG_FILE
    systemctl start docker >> $LOG_FILE 2>&1 || echo "ERROR: Docker start failed with $?" >> $LOG_FILE
    
    # Create docker group but don't add users (production security practice)
    echo "Creating docker group (but not adding users for security)" >> $LOG_FILE
    groupadd -f docker >> $LOG_FILE 2>&1 || echo "Docker group already exists" >> $LOG_FILE
    
    # Install Docker Compose
    echo "Installing Docker Compose" >> $LOG_FILE
    wait_for_apt || { echo "ERROR: Could not acquire apt locks, continuing anyway" >> $LOG_FILE; }
    apt-get -y install docker-compose-plugin >> $LOG_FILE 2>&1 || echo "ERROR: Docker Compose installation failed with $?" >> $LOG_FILE
    
    # Create a symlink for backwards compatibility
    ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose 2>> $LOG_FILE || echo "ERROR: Docker Compose symlink failed with $?" >> $LOG_FILE
    
    echo "Docker status:" >> $LOG_FILE
    systemctl status docker | head -20 >> $LOG_FILE 2>&1
    docker --version >> $LOG_FILE 2>&1 || echo "ERROR: Docker version check failed with $?" >> $LOG_FILE
fi
#endregion

#region SECURITY HARDENING
#########################
### SECURITY HARDENING ###
#########################
# TO BE IMPLEMENTED
echo "Security hardening section needs implementation" >> $LOG_FILE
#endregion

#region FIREWALL SETUP
#####################
### FIREWALL SETUP ###
#####################
# TO BE IMPLEMENTED
echo "Firewall setup section needs implementation" >> $LOG_FILE
#endregion

#region USER CONFIGURATION
#########################
### USER CONFIGURATION ###
#########################
# Customize TTY prompt for all users
echo "Customizing TTY prompt" >> $LOG_FILE
sed -i 's/#force_color_prompt=yes/ force_color_prompt=yes/' /etc/skel/.bashrc
sed -i 's/\\\[\\033\[01;32m\\\]\\u@\\h\\\[\\033\[00m\\\]:\\\[\\033\[01;34m\\\]\\w\\\[\\033\[00m\\\]\\\$ /\\n\\@ \\\[\\e\[32;40m\\\]\\u\\\[\\e\[m\\\] \\\[\\e\[32;40m\\\]@\\\[\\e\[m\\\]\\n \\\[\\e\[32;40m\\\]\\H\\\[\\e\[m\\\] \\\[\\e\[36;40m\\\]\\w\\\[\\e\[m\\\] \\\[\\e\[33m\\\]\\\\\$\\\[\\e\[m\\\] /' /etc/skel/.bashrc

# Add useful aliases to skel
echo "Adding useful aliases" >> $LOG_FILE
cat > /etc/skel/.bash_aliases << 'EOF'
# System aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias update='sudo apt update && sudo apt upgrade -y'
alias cls='clear'

# Docker aliases
alias d='docker'
alias dc='docker-compose'
alias dps='docker ps'
alias dex='docker exec -it'
EOF

# Apply to current users' .bashrc files as well
for user_home in /home/*; do
    if [ -d "$user_home" ]; then
        username=$(basename "$user_home")
        if [ -f "$user_home/.bashrc" ]; then
            echo "Updating prompt for user $username" >> $LOG_FILE
            sed -i 's/#force_color_prompt=yes/ force_color_prompt=yes/' "$user_home/.bashrc"
            sed -i 's/\\\[\\033\[01;32m\\\]\\u@\\h\\\[\\033\[00m\\\]:\\\[\\033\[01;34m\\\]\\w\\\[\\033\[00m\\\]\\\$ /\\n\\@ \\\[\\e\[32;40m\\\]\\u\\\[\\e\[m\\\] \\\[\\e\[32;40m\\\]@\\\[\\e\[m\\\]\\n \\\[\\e\[32;40m\\\]\\H\\\[\\e\[m\\\] \\\[\\e\[36;40m\\\]\\w\\\[\\e\[m\\\] \\\[\\e\[33m\\\]\\\\\$\\\[\\e\[m\\\] /' "$user_home/.bashrc"
            chown $username:$username "$user_home/.bashrc"
        fi
        
        # Copy aliases file
        cp /etc/skel/.bash_aliases "$user_home/.bash_aliases"
        chown $username:$username "$user_home/.bash_aliases"
    fi
done
#endregion

#region WORDPRESS SETUP
######################
### WORDPRESS SETUP ###
######################
# TO BE IMPLEMENTED
echo "WordPress setup section needs implementation" >> $LOG_FILE
#endregion

#region GIT REPOSITORY SETUP
##########################
### GIT REPOSITORY SETUP ###
##########################
# TO BE IMPLEMENTED
echo "Git repository setup section needs implementation" >> $LOG_FILE
#endregion

#region WORDPRESS DEPLOYMENT
############################
### WORDPRESS DEPLOYMENT ###
############################
# TO BE IMPLEMENTED
echo "WordPress deployment section needs implementation" >> $LOG_FILE
#endregion

#region COMPLETION
#################
### COMPLETION ###
#################
echo "=== SERVER BOOT SCRIPT COMPLETED at $(date) ===" >> $LOG_FILE
echo "Final system status:" >> $LOG_FILE
df -h >> $LOG_FILE
free -h >> $LOG_FILE

# Verify Docker installation
if command -v docker &> /dev/null; then
    echo "Docker installation SUCCESSFUL" >> $LOG_FILE
    docker --version >> $LOG_FILE 2>&1
    systemctl status docker --no-pager >> $LOG_FILE 2>&1 || true
else
    echo "WARNING: Docker command not available after installation" >> $LOG_FILE
fi

# Create a marker file to indicate completion
touch /tmp/server-boot-completed

# Simple completion message 
echo "Script completed successfully at $(date). Check $LOG_FILE for details."
#endregion