#!/bin/bash

set -euo pipefail

# === Globals ===
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DIR=$(pwd)
LOGFILE="$DIR/deploy_$TIMESTAMP.log"

# === Logging Functions ===
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "$LOGFILE"
}

log_success() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $*" | tee -a "$LOGFILE"
}

die() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOGFILE"
    exit 1
}


# === Main Script ===
log "Starting setup..."
log "Saving logs to $LOGFILE"


trap 'die "Script interrupted unexpectedly."' INT TERM

# === Prompt for User Input ===
read -rp "Enter Git Repository URL: " GIT_REPO
[[ -z "$GIT_REPO" ]] && die "Git Repository URL is required."
log_success "Git Repository URL set as: $GIT_REPO"

read -rsp "Enter your Git Personal Access Token (PAT): " GIT_PAT
echo
[[ -z "$GIT_PAT" ]] && die "Personal Access Token is required."
log_success "Personal Access Token received."

read -rp "Enter Git branch (default: main): " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}
log_success "Git branch set as: $GIT_BRANCH"

read -rp "Remote SSH Username: " SSH_USER
[[ -z "$SSH_USER" ]] && die "SSH username is required."
log_success "SSH Username set as: $SSH_USER"

read -rp "Remote Server IP Address: " SERVER_IP
[[ -z "$SERVER_IP" ]] && die "Server IP is required."
log_success "Server IP set as: $SERVER_IP"

read -rp "Path to your SSH private key: " SSH_KEY
[[ ! -f "$SSH_KEY" ]] && die "SSH key not found at $SSH_KEY."
SSH_KEY=$(realpath "$SSH_KEY")
log_success "SSH Key path set as: $SSH_KEY"

read -rp "Application internal container port (default: 3000): " APP_PORT
APP_PORT=${APP_PORT:-3000}
log_success "Application port set as: $APP_PORT"

# === Clone or Update Repo ===
REPO_NAME=$(basename "$GIT_REPO" .git)

log "Cloning or updating repository..."
if [[ -d "$REPO_NAME" ]]; then
    log "Repository already exists. Pulling latest changes..."
    cd "$REPO_NAME" || die "Failed to cd into $REPO_NAME"
    git checkout "$GIT_BRANCH" || die "Branch $GIT_BRANCH not found."
    log "Checked out branch $GIT_BRANCH."
    git pull || die "Git pull failed."
    log "Pulled latest changes."
else
    AUTH_REPO_URL=${GIT_REPO/https:\/\//https:\/\/$GIT_PAT@}
    git clone --branch "$GIT_BRANCH" "$AUTH_REPO_URL" "$REPO_NAME" || die "Git clone failed."
    log_success "Cloned repository successfully."
    cd "$REPO_NAME" || die "Failed to cd into $REPO_NAME"
    log "Changed working directory to $REPO_NAME."
fi

# === Check for Dockerfile or docker-compose.yaml ===
log "Checking for docker or docker-compose file."
if [[ -f "docker-compose.yaml" ]]; then
    DEPLOY_METHOD="docker-compose"
    log_success "Found docker-compose.yaml file."
elif [[ -f "Dockerfile" ]]; then
    DEPLOY_METHOD="docker"
    log_success "Found Dockerfile."
else
    die "No Dockerfile or docker-compose.yml found."
fi

log "Deployment method set as: $DEPLOY_METHOD."

# === Check for SSH Key Accessibility ===
if [[ ! -r "$SSH_KEY" ]]; then
    die "SSH key at $SSH_KEY is not readable."
    else
    log_success "SSH key is accessible."
fi

# === SSH Connectivity Check ===
log "Testing SSH connection to $SERVER_IP..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$SERVER_IP" "echo SSH connection successful" \
    || die "SSH connection test failed."
log_success "SSH connection test passed."

# === Remote Setup Commands ===
log "Setting up remote server..."
REMOTE_SETUP=$(cat << EOF
set -e
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose nginx
sudo usermod -aG docker $SSH_USER
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx
docker --version
docker-compose --version
nginx -v
EOF
)

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "$REMOTE_SETUP" || die "Remote setup failed."
log_success "Remote server setup completed."

# === Transfer Project Files ===
log "Transferring project files to remote server..."
scp -r -i "$SSH_KEY" ./* "$SSH_USER@$SERVER_IP:~/app" || die "Failed to transfer files."
log_success "File transfer to server at $SERVER_IP successful."

# === Deploy Application ===
log "Configuration deployment command."
DEPLOY_CMD=""
if [[ "$DEPLOY_METHOD" == "docker-compose" ]]; then
    DEPLOY_CMD="cd ~/app && sudo docker-compose down && sudo docker-compose up -d"
else
    DEPLOY_CMD="cd ~/app && sudo docker build -t myapp . && sudo docker stop myapp || true && sudo docker rm myapp || true && sudo docker run -d --name myapp -p $APP_PORT:$APP_PORT myapp"
fi
log_success "Deployment command successfully set."

log "Deploying application..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "$DEPLOY_CMD" || die "Deployment failed."
log_success "App deployment successful."

# === Configure Nginx Reverse Proxy ===
log "Configuring Nginx Reverse Proxy..."
NGINX_CONFIG="
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
"

log "Applying configuration..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "echo '$NGINX_CONFIG' | sudo tee /etc/nginx/sites-available/default > /dev/null && sudo nginx -t && sudo systemctl reload nginx" || die "Nginx configuration failed."
log_success "Nginx Reverse Proxy successfully configured."

# === Final Checks ===
log "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "curl -s -o /dev/null -w '%{http_code}' http://localhost" | grep -q "200" \
    && log_success "Deployment successful and accessible." \
    || die "Deployment completed, but app is not responding."

log "All steps completed successfully."
