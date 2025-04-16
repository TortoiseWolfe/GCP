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