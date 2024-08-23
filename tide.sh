#!/bin/bash

# tide.sh
# easily deploy containerized applications to digitalocean.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
WHITEBOLD='\033[1m\033[97m' # White bold

# Global variables
ENV_FILE=""
SSH_ONLY=false
FORCE=false
DESTROY=false
LIST=false
REFRESH_EVARS=false
INSTALL_DEPS=false
AUDIT_ONLY=false
DEPLOY=false
COMMAND_PROVIDED=false
START_APP=false
RE_DEPLOY=false
CHECK_PORTS=false

# Function to display help menu
display_help() {
    echo "tide.sh: deploy containerized applications to DigitalOcean"
    echo "Usage: $0 [options] <command>"
    echo "Options:"
    echo "  -e, --env <file>         Specify environment file"
    echo "  --help                   Display this help menu"
    echo "Commands:"
    echo "  deploy                   Deploy to remote"
    echo "  ssh                      SSH into the remote"
    echo "  destroy                  Terminate and remove the remote"
    echo "  list                     List droplets visible to the provided keys"
    echo "  refresh-evars            Refresh environment variables on the remote"
    echo "  install-deps             Install dependencies (only) on the remote"
    echo "  audit-only               Run security audit of the remote"
    echo "  start-app                Start (docker compose up --build)"
    echo "  re-deploy                [Git hook-style, when repo is updated]: re-clone, re-build compose/containers, and re-start."
    echo "  check-ports              view the open ports on the remote. (docker has iptables rw, so ufw status won't get you there.)"
    exit 1
}

# Function to handle error exit
function error_exit {
    echo -e "${RED}Error: $1${NC}"
    exit 1
}

# Function to prompt user for confirmation
function confirm_action {
    read -p "$1 [y/n]: " -n 1 -r
    echo    # Move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Action aborted by user.${NC}"
        exit 1
    fi
}

# Function to source environment variables
function source_env_file {
    if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
        error_exit "Environment file must be provided with -e <env_file> and it must exist."
    fi
    echo "Sourcing environment file: $ENV_FILE"
    source "$ENV_FILE"
}

# Function to authenticate with DigitalOcean
function authenticate_doctl {
    if [ -z "$DIGITALOCEAN_ACCESS_TOKEN" ]; then
        error_exit "DIGITALOCEAN_ACCESS_TOKEN is not set. Please export your DigitalOcean API token."
    fi
    echo "Authenticating with DigitalOcean..."
    doctl auth init -t "$DIGITALOCEAN_ACCESS_TOKEN"
}

function manage_ssh_keys {
    echo "Managing SSH keys for interacting with $DROPLET_NAME..."
    if ! doctl compute ssh-key list | awk '{ print $2 }' | grep $SSH_KEY_ID > /dev/null; then
        PUBLIC_SSH_KEY_CONTENT=$(cat "$SSH_PUBLIC_KEY_FILE")
        
        # Check if the content of the public key was retrieved successfully
        if [ -z "$PUBLIC_SSH_KEY_CONTENT" ]; then
            echo "Error: Unable to read public SSH key from $PUBLIC_SSH_KEY_FILE"
        fi
        
        doctl compute ssh-key create $SSH_KEY_ID --public-key "$PUBLIC_SSH_KEY_CONTENT"
        echo "Created ssh key on DO: $SSH_KEY_ID"
    else
        SSH_KEY_FINGERPRINT=$(doctl compute ssh-key list | grep $SSH_KEY_ID | awk '{ print $3 }')
        echo " > confirmed ssh key ($SSH_KEY_ID) is setup in digital ocean (fingerprint: $SSH_KEY_FINGERPRINT)"
    fi
}

# Function to list existing droplets
function list_droplets {
    echo "Listing existing droplets..."
    doctl compute droplet list
}

# Function to check if droplet exists
function droplet_exists {
    local DROPLET_INFO=$(doctl compute droplet list --no-header --format "ID,Name,Status,Public IPv4" | grep "$DROPLET_NAME")
    if [ -z "$DROPLET_INFO" ]; then
        return 1  # Droplet does not exist
    else
        DROPLET_ID=$(echo "$DROPLET_INFO" | awk '{print $1}')
        DROPLET_IP=$(echo "$DROPLET_INFO" | awk '{print $4}')
        return 0  # Droplet exists
    fi
}

# Function to wait for droplet to become active
function wait_for_droplet_status {
    local expected_status=$1
    local timeout_seconds=$2
    local elapsed_seconds=0

    echo -e "Waiting for droplet status to become '$expected_status'..."
    while [[ $(doctl compute droplet get "$DROPLET_ID" --format Status --no-header) != "$expected_status" ]]; do
        sleep 5
        elapsed_seconds=$((elapsed_seconds + 5))
        if [ $elapsed_seconds -ge $timeout_seconds ]; then
            error_exit "Timed out waiting for droplet to reach status '$expected_status'."
        fi
    done
    
    droplet_exists
    echo -e "${GREEN}Success: ${NC}Droplet status is now '$expected_status'."
}

# Function to create a new droplet
function create_droplet {
    if droplet_exists; then
        error_exit "A droplet with the name $DROPLET_NAME already exists. Use --force to recreate it."
    fi
    
    confirm_action "Are you sure you want to create a new droplet named $DROPLET_NAME?"

    echo "Creating a new droplet named $DROPLET_NAME..."
    DROPLET_ID=$(doctl compute droplet create "$DROPLET_NAME" \
        --size s-1vcpu-1gb-amd \
        --image ubuntu-20-04-x64 \
        --region nyc1 \
        --ssh-keys "$SSH_KEY_FINGERPRINT" \
        --wait --format ID --no-header)

    if [ -z "$DROPLET_ID" ]; then
        error_exit "Droplet could not be created."
    fi
    
    wait_for_droplet_status "active" 120 # Wait for bootup

    echo -e "${GREEN}Success: ${NC}Droplet created with IP address: $DROPLET_IP"
}

# Function to destroy an existing droplet
function destroy_droplet {
    if ! droplet_exists; then
        echo -e "${RED}Warning: ${NC}No droplets found with the name $DROPLET_NAME to destroy."
        exit 0
    fi

    confirm_action "Are you sure you want to destroy the droplet named $DROPLET_NAME?"

    echo -e "${RED}Warning: ${NC}Destroying droplet named $DROPLET_NAME..."
    doctl compute droplet delete "$DROPLET_ID" --force || error_exit "Failed to destroy droplet with ID $DROPLET_ID."

    # Wait for droplet to be completely removed
    local elapsed_seconds=0
    local timeout_seconds=120  # Wait up to n seconds
    echo -e "Waiting for droplet to be fully removed..."
    while droplet_exists; do
        sleep 5
        elapsed_seconds=$((elapsed_seconds + 5))
        if [ $elapsed_seconds -ge $timeout_seconds ]; then
            error_exit "Timed out waiting for droplet to be fully removed."
        fi
    done

    echo -e "${GREEN}Success: ${NC}Droplet named $DROPLET_NAME has been destroyed."
}

# Function to manage the droplet lifecycle
function manage_droplet {
    # Handle teardown mode
    if [ "$DESTROY" = true ]; then
        destroy_droplet
        exit 0
    fi

    # Handle force mode (destroy and recreate)
    if [ "$FORCE" = true ]; then
        destroy_droplet
        create_droplet
    elif ! droplet_exists; then
        # If no droplet exists, create a new one
        create_droplet
    else
        error_exit "A droplet named $DROPLET_NAME already exists. Use --force to destroy and recreate it."
    fi
}

# Function to wait for SSH to be ready, optionally with port parameter
function wait_for_ssh {
    local port="${1:-22}"
    local timeout_seconds=300
    local elapsed_seconds=0
    
    echo "Waiting for SSH to be ready on port $port..."
    until ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -i $SSH_KEY_PATH root@$DROPLET_IP -p "$port" true; do
        sleep 5
        elapsed_seconds=$((elapsed_seconds + 5))
        if [ $elapsed_seconds -ge $timeout_seconds ]; then
            error_exit "SSH connection timed out after $((timeout_seconds / 60)) minutes."
        fi
    done
    echo -e "${GREEN}Success: ${NC}SSH is ready on port $port."
}

# Function to secure the droplet
function secure_droplet {
    wait_for_ssh
    ssh -t -oStrictHostKeyChecking=no -i $SSH_DIR/$SSH_KEY_ID root@$DROPLET_IP << 'ENDSSH'
        until sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
            echo "Waiting for other software managers to finish..."
            sleep 2
        done
        sudo apt-get update -y
        sudo DEBIAN_FRONTEND=noninteractive apt-get -yq upgrade
        sudo shutdown -r now
ENDSSH
    SSH_EXIT_STATUS=$?

    if [ $SSH_EXIT_STATUS -ne 0 ] && [ $SSH_EXIT_STATUS -ne 255 ] && [ $SSH_EXIT_STATUS -ne 130 ]; then
        error_exit "Failed to apt-get update && apt-get upgrade on remote."
    fi

    wait_for_droplet_status "active" 120
    wait_for_ssh

    ssh -oStrictHostKeyChecking=no -i $SSH_DIR/$SSH_KEY_ID root@$DROPLET_IP << ENDSSH
        adduser --disabled-password --gecos "" $USER_NAME
        echo "${USER_NAME} ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME}_nopasswd
        chmod 0440 /etc/sudoers.d/${USER_NAME}_nopasswd
        rsync --archive --chown=$USER_NAME:$USER_NAME ~/.ssh /home/$USER_NAME
        ufw allow 2202/tcp
        sed -i 's/#Port 22/Port 2202/' /etc/ssh/sshd_config
        service ssh restart
        yes | ufw enable
        sudo shutdown -r now
ENDSSH
    SSH_EXIT_STATUS=$?

    if [ $SSH_EXIT_STATUS -ne 0 ] && [ $SSH_EXIT_STATUS -ne 255 ] && [ $SSH_EXIT_STATUS -ne 130 ]; then
        error_exit "Failed to create $USER_NAME on remote and lock down security settings including move ssh to alternative port."
    fi

    echo "Moved remote SSH to port 2202"
    wait_for_droplet_status "active" 120
    wait_for_ssh 2202
    
    ssh -oStrictHostKeyChecking=no -i $SSH_DIR/$SSH_KEY_ID $USER_NAME@$DROPLET_IP -p 2202 << 'ENDSSH'
        sudo dpkg --configure -a
        echo 'export PATH=$PATH:/home/`whoami`/.local/bin' >> ~/.bashrc
ENDSSH
    SSH_EXIT_STATUS=$?

    if [ $SSH_EXIT_STATUS -ne 0 ] && [ $SSH_EXIT_STATUS -ne 255 ] && [ $SSH_EXIT_STATUS -ne 130 ]; then
        error_exit "Failed to finish securing remote."
    fi

}

# Function to transfer environment variables to remote server and expand them there for ready use.
function transfer_env_vars {
    local env_file="$1"
    local exclude_var_name="${2:-EXCLUDED_FROM_DEPLOYMENT}"
    local remote_path="$3"
    local temp_file=$(mktemp)

    # Function to exclude variables based on exclusion criteria
    function filter_excluded_vars {
        local exclude_list=($(grep -oP "^${exclude_var_name}=\K.*" "$env_file" | tr ',' ' '))
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local var_name="${line%=*}"
            if [[ ! " ${exclude_list[@]} " =~ " $var_name " ]]; then
                echo "$line"
            fi
        done < "$env_file"
    }

    # Write filtered environment variables to a temporary file
    filter_excluded_vars > "$temp_file"

    wait_for_droplet_status "active" 120
    wait_for_ssh 2202

    scp -P 2202 -i "$SSH_DIR/$SSH_KEY_ID" "$temp_file" "$USER_NAME@$DROPLET_IP:/home/$USER_NAME/.env" || error_exit "Failed to transfer .env file."
    rm "$temp_file"
    echo -e "${GREEN}Success: ${NC}Environment variables copied to remote server. Proceeding to remotely expand them."

    ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
    # Local expansion of environment variables in case they are templated
    TEMP_FILE=$(mktemp)
    set -a
    source .env
    set +a
    EXCLUDED_VARS=$(grep -oP '^EXCLUDED_FROM_REMOTE_EXPANSION=\K.*' .env | tr ',' '|')
    while IFS= read -r line; do
        VAR_NAME=$(echo $line | cut -d= -f1)
        ORIGINAL_VALUE=$(echo $line | cut -d= -f2-)
        
        if ! [[ $VAR_NAME =~ ^($EXCLUDED_VARS)$ ]]; then
            if [[ $ORIGINAL_VALUE =~ ^\".*\"$ ]]; then
                eval VALUE=\$$VAR_NAME
                echo "$VAR_NAME=\"$VALUE\"" >> $TEMP_FILE
            elif [[ $ORIGINAL_VALUE =~ ^\'.*\'$ ]]; then
                eval VALUE=\$$VAR_NAME
                echo "$VAR_NAME='$VALUE'" >> $TEMP_FILE
            else
                eval echo "$VAR_NAME=\$$VAR_NAME" >> $TEMP_FILE
            fi
        else
            echo $line >> $TEMP_FILE
        fi
    done < .env
    mv $TEMP_FILE .env

    # Ensure .env is sourced on SSH login
    # Add to .bashrc if not already present
    REMOTE_EVARS_CHECK_ACTION='if [ -f "$HOME/.env" ]; then set -a; source "$HOME/.env"; set +a; fi'
    [ ! -f "$HOME/.bash_profile" ] || touch $HOME/.bash_profile
    if ! grep -qF "$REMOTE_EVARS_CHECK_ACTION" $HOME/.bash_profile; then
        echo $REMOTE_EVARS_CHECK_ACTION >> ~/.bash_profile || { echo "Failed to update remote .bash_profile, evars will not be auto-sourced on login." ; exit 1; }
    fi

ENDSSH

    if [ $? -ne 0 ]; then
        error_exit "Failed to expand environment variables on the remote server."
    fi

    echo -e "${GREEN}Success: ${NC}Environment variables expanded and available within/on $DROPLET_NAME ($DROPLET_IP)."
}

# Function to install necessary dependencies on remote server
function install_dependencies {
    # copy up the tide_finalbootstrap.sh script to be run after dependencies are installad.
    scp -P 2202 -i "$SSH_DIR/$SSH_KEY_ID" "tide_finalbootstrap.sh" "$USER_NAME@$DROPLET_IP:/home/$USER_NAME/tide_finalbootstrap.sh" || error_exit "Failed to transfer tide_finalbootstrap.sh file."

    ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
        set -a
        source .env
        set +a

        chmod +x /home/$USER_NAME/tide_finalbootstrap.sh

        # just for convenience, add a remote vimrc with basics 
        cat << 'EOVIMRC' >> ~/.vimrc
    inoremap kj <Esc>
    " Set the number of spaces that a <Tab> counts for
    set tabstop=4
    " Set the number of spaces to use for each step of (auto)indent
    set shiftwidth=4
    " Convert tabs to spaces
    set expandtab
    " Enable auto-indenting of new lines
    set autoindent
    set smartindent
    " Make backspace behave in a sane manner
    set backspace=indent,eol,start
    " Show existing tab with 4 spaces width
    set softtabstop=4
    " Enable syntax highlighting
    syntax on
    " Enable file type detection, which sets appropriate settings for Dockerfiles
    filetype plugin indent on
    " Display line numbers
    set number
EOVIMRC

        # Update the package list and install prerequisites
        sudo apt-get update -y
        sudo apt-get install -y ca-certificates curl gnupg

        # Add Docker's official GPG key:
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        # Set up the Docker repository:
        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Update the package list again and install Docker
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Cleanup
        sudo dpkg --list | grep '^rc' | awk '{print $2}' | xargs sudo apt-get purge -y

        # permissions
        sudo groupadd docker
        sudo usermod -aG docker $USER_NAME
        newgrp docker

        # Test Docker installation
        docker run hello-world || { echo "Unable to audit system or audit cancelled." ; exit 1; }
        docker compose --version || { echo "Unable to run docker compose normally." ; exit 1; }

        # Clone the repository if it doesn't exist, otherwise pull the latest changes
        if [ ! -z "$REPO_URL" ]; then
            if [ ! -d "$REPO_NAME" ]; then
                git clone "$REPO_URL" "$REPO_NAME"
                cd "$REPO_NAME" || { echo "Unable to clone repo ($REPO_URL)." ; exit 1; }
                [ -n "$BRANCH_NAME" ] && git checkout "$BRANCH_NAME"
            else
                cd "$REPO_NAME" || { echo "Unable to enter repo directory ($REPO_NAME)." ; exit 1; }
                git fetch --all
                git reset --hard origin/$(git symbolic-ref --short HEAD)
                git pull || { echo "Unable to pull latest changes." ; exit 1; }

                # note: this option of overwrite (vs. stash+pull, automerge, or pull+rebase, was chosen as default because the remote is not expected to be manually managed)
                echo "Successfully overwrote repo contents."
            fi
        else
            env
            echo "Repo ($REPO_URL) not found in environment. Will not be cloned or updated."
            exit 1
        fi

        if grep -q $'\r' "$HOME/tide_finalbootstrap.sh"; then
            echo "Windows line endings detected. Converting all .sh files in $HOME to Unix format..."
            
            # Convert all .sh files in $HOME to Unix format
            find $HOME -type f -name "*.sh" -exec sed -i 's/\r//' {} +
            
            echo "Conversion complete."
        else
            echo "No Windows line endings detected. Running the script as is..."
        fi

        # Set executable permissions on all .sh files, particularly important for docker entrypoints.
        find $HOME -type f -name "*.sh" -exec chmod +x {} +

        echo "Permissions set."
        echo "Running $HOME/tide_finalbootstrap.sh..."
        bash "$HOME/tide_finalbootstrap.sh"
ENDSSH

    [ $? -ne 0 ] && error_exit "Failed to install dependencies on remote."

    echo -e "${GREEN}Success: ${NC}Installed dependencies including $REPO_NAME on $DROPLET_NAME ($DROPLET_IP)."

}

function ssh_into_droplet {
    if droplet_exists; then
        echo "SSHing into the droplet with IP $DROPLET_IP (key path @ $SSH_KEY_PATH)"
        ssh -i "$SSH_KEY_PATH" $USER_NAME@$DROPLET_IP -p 2202
        SSH_EXIT_STATUS=$?

        if [ $SSH_EXIT_STATUS -ne 0 ] && [ $SSH_EXIT_STATUS -ne 255 ] && [ $SSH_EXIT_STATUS -ne 130 ]; then
            error_exit "Failed to SSH into the droplet. SSH exited with status $SSH_EXIT_STATUS."
        fi

        exit 0
    else
        error_exit "No droplets found with the name $DROPLET_NAME."
    fi
}

function audit {
    ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
        source .env
        command -v lynis &> /dev/null
        [ $? -ne 0 ] && echo "Lynis is not installed. Installing..." && sudo apt-get update -y && sudo apt-get install lynis -y
        sudo lynis audit system
ENDSSH

    [ $? -ne 0 ] && error_exit "Unable to audit system or audit cancelled."

    echo "Audit logs can generally be found on remote at /var/log/lynis.log and /var/log/lynis-report.dat."
}

function start_app {
    echo "WARNING: Not tested."
    ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
        cd $HOME/$REPO_NAME
        docker compose down
        docker compose up --build -d
ENDSSH

    [ $? -ne 0 ] && error_exit "Unable to re/start app"
}


function cleanup {
    echo "WARNING: Not tested."
    ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
        source .env
        sudo dpkg --list | grep '^rc' | awk '{print $2}' | xargs sudo apt-get purge -y
ENDSSH

    [ $? -ne 0 ] && error_exit "Unable to cleanup."
}

function re_deploy {
    ALSO_RESTART=${1:-false} 

    transfer_env_vars "$ENV_FILE" "EXCLUDED_FROM_DEPLOYMENT" "/home/$USER_NAME/.env"
    scp -P 2202 -i "$SSH_DIR/$SSH_KEY_ID" "tide_finalbootstrap.sh" "$USER_NAME@$DROPLET_IP:/home/$USER_NAME/tide_finalbootstrap.sh" || error_exit "Failed to transfer tide_finalbootstrap.sh file."

    ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
        set -a
        source .env
        set +a
        cd $HOME/$REPO_NAME
        git reset --hard HEAD
        git fetch origin
        git reset --hard origin/main
        cd $HOME

        # replicated from install_dependencies, todo: DRY
        if grep -q $'\r' "$HOME/tide_finalbootstrap.sh"; then
            echo "Windows line endings detected. Converting all .sh files in $HOME to Unix format..."
            
            # Convert all .sh files in $HOME to Unix format
            find $HOME -type f -name "*.sh" -exec sed -i 's/\r//' {} +
            
            echo "Conversion complete."
        else
            echo "No Windows line endings detected. Running the script as is..."
        fi

        # Set executable permissions on all .sh files, particularly important for docker entrypoints.
        find $HOME -type f -name "*.sh" -exec chmod +x {} +

        echo "Permissions set."
        echo "Running $HOME/tide_finalbootstrap.sh..."
        bash "$HOME/tide_finalbootstrap.sh"
ENDSSH

    [ $? -ne 0 ] && error_exit "Unable to fetch latest from git remote. Redeploy failed."

    if $ALSO_RESTART; then
        ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
            ./tide_finalbootstrap.sh
            cd $HOME/$REPO_NAME
            if "$ALSO_RESTART"; then
                echo 'Forced to also restart, so doing that...'
                docker compose build
                docker compose up -d --no-deps --build
            fi
ENDSSH
    fi

    [ $? -ne 0 ] && error_exit "Unable to redeploy."

    echo "Deployment steps did complete, but please confirm (docker ps on remote, and via live site)"
}

function check_ports {
    echo "WARNING: Not tested."
    ssh -i "$SSH_DIR/$SSH_KEY_ID" "$USER_NAME@$DROPLET_IP" -p 2202 << 'ENDSSH'
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo "FIREWALL RULES"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        iptables -L -n -v
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo "PORTS SUMMARY"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        sudo ss -tuln
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
ENDSSH
}

# Parse command-line arguments
while [ "$1" != "" ]; do
    case $1 in
        -e | --env )        shift
                            ENV_FILE=$1
                            ;;
        deploy | ssh | destroy | list | refresh-evars | install-deps | audit-only | start-app | re-deploy | check-ports )
                            COMMAND_PROVIDED=true
                            COMMAND=$1
                            ;;
        --force )           FORCE=true
                            ;;
        --help )            display_help
                            ;;
        * )                 display_help
                            exit 1
                            ;;
    esac
    shift
done

# Ensure a valid command was provided
if [ "$COMMAND_PROVIDED" = false ]; then
    display_help
    exit 1
fi

# Ensure the environment file is provided and valid
if [ -z "$ENV_FILE" ]; then
    echo "Environment file is required."
    display_help
    exit 1
fi

source_env_file
authenticate_doctl

case $COMMAND in
    list)
        echo "Listing droplets"
        list_droplets
        ;;
    ssh)
        echo "SSHing in"
        if droplet_exists; then
            ssh_into_droplet
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    refresh-evars)
        echo "Refreshing evars"
        if droplet_exists; then
            transfer_env_vars "$ENV_FILE" "EXCLUDED_FROM_DEPLOYMENT" "/home/$USER_NAME/.env"
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    install-deps)
        echo "Installing deps only"
        if droplet_exists; then
            install_dependencies
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    audit-only)
        echo "Audit only"
        if droplet_exists; then
            audit
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    start-app)
        echo "Start app"
        if droplet_exists; then
            start_app
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    destroy)
        echo "Destroy"
        if droplet_exists; then
            destroy_droplet
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    check-ports)
        echo "Check ports"
        if droplet_exists; then
            check_ports
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    deploy)
        echo "Deploying"
        manage_ssh_keys
        manage_droplet
        secure_droplet
        transfer_env_vars "$ENV_FILE" "EXCLUDED_FROM_DEPLOYMENT" "/home/$USER_NAME/.env"
        install_dependencies
        #cleanup
        #audit
        echo -e "${GREEN}Success: ${NC}Deployment finished. Please update your DNS A record to point to $DROPLET_IP."
        ;;
    re-deploy)
        echo "Redeploy"
        if droplet_exists; then
            re_deploy $FORCE
        else
            error_exit "Droplet does not exist."
        fi
        ;;
    *)
        display_help
        exit 1
        ;;
esac

doctl auth remove --context default || true