#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment variables
if [ ! -f "env.sh" ]; then
    echo -e "${RED}Error: env.sh not found. Please copy env.sh.example to env.sh and configure it.${NC}"
    exit 1
fi

source env.sh

# Map RHDP variable names to ARM_* variables (for Terraform compatibility)
# This allows users to copy-paste variables directly from Red Hat Demo Platform
if [ -n "${CLIENT_ID:-}" ] && [ -z "${ARM_CLIENT_ID:-}" ]; then
  export ARM_CLIENT_ID="$CLIENT_ID"
fi
if [ -n "${PASSWORD:-}" ] && [ -z "${ARM_CLIENT_SECRET:-}" ]; then
  export ARM_CLIENT_SECRET="$PASSWORD"
fi
if [ -n "${SUBSCRIPTION:-}" ] && [ -z "${ARM_SUBSCRIPTION_ID:-}" ]; then
  export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION"
fi
if [ -n "${TENANT:-}" ] && [ -z "${ARM_TENANT_ID:-}" ]; then
  # If TENANT is a domain name, try to get tenant ID using Service Principal login
  if [[ ! "$TENANT" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    # It's a domain name, try to get tenant ID using Service Principal
    if [ -n "${ARM_CLIENT_ID:-}" ] && [ -n "${ARM_CLIENT_SECRET:-}" ] && [ -n "${ARM_SUBSCRIPTION_ID:-}" ]; then
      echo -e "${GREEN}Resolving tenant domain to ID using Service Principal...${NC}"
      TENANT_ID=$(az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$TENANT" --query tenantId -o tsv 2>/dev/null || echo "")
      if [ -n "$TENANT_ID" ]; then
        export ARM_TENANT_ID="$TENANT_ID"
        echo -e "${GREEN}Tenant ID resolved: $TENANT_ID${NC}"
      else
        echo -e "${YELLOW}Warning: Could not resolve tenant domain to ID. You may need to set TENANT to the tenant ID (GUID) instead of domain name.${NC}"
        export ARM_TENANT_ID="$TENANT"
      fi
    else
      echo -e "${YELLOW}Warning: TENANT is a domain name but Service Principal credentials are not available. Using domain name as-is.${NC}"
      echo -e "${YELLOW}Note: If this causes issues, please set TENANT to the tenant ID (GUID) instead.${NC}"
      export ARM_TENANT_ID="$TENANT"
    fi
  else
    export ARM_TENANT_ID="$TENANT"
  fi
fi
if [ -n "${RESOURCEGROUP:-}" ] && [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  export AZURE_RESOURCE_GROUP="$RESOURCEGROUP"
fi

# Check required tools
echo -e "${GREEN}Checking required tools...${NC}"
for cmd in terraform az oc ansible-playbook; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: $cmd is not installed${NC}"
        exit 1
    fi
done

# Check Azure authentication
echo -e "${GREEN}Checking Azure authentication...${NC}"
# If Service Principal is configured, we don't need az login
if [ -n "${ARM_CLIENT_ID:-}" ] && [ -n "${ARM_CLIENT_SECRET:-}" ] && [ -n "${ARM_TENANT_ID:-}" ] && [ -n "${ARM_SUBSCRIPTION_ID:-}" ]; then
    echo -e "${GREEN}Service Principal authentication configured. Skipping Azure CLI login check.${NC}"
    # Optionally, login with Service Principal for az commands (for cluster management)
    if ! az account show &> /dev/null; then
        echo -e "${GREEN}Logging in with Service Principal for Azure CLI commands...${NC}"
        az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" > /dev/null 2>&1 || true
    fi
else
    # If Service Principal is not configured, check Azure CLI authentication
    if ! az account show &> /dev/null; then
        echo -e "${YELLOW}Warning: Azure CLI is not authenticated and Service Principal is not configured.${NC}"
        echo -e "${YELLOW}Please either:${NC}"
        echo -e "${YELLOW}  1. Run 'az login' for Azure CLI authentication, or${NC}"
        echo -e "${YELLOW}  2. Set Service Principal credentials (CLIENT_ID, PASSWORD, TENANT, SUBSCRIPTION)${NC}"
        exit 1
    fi
fi

# Set default values if not set
export AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${RESOURCEGROUP:-aro-rg}}"
export AZURE_VNET_NAME="${AZURE_VNET_NAME:-aro-vnet}"
export ARO_CLUSTER_NAME="${ARO_CLUSTER_NAME:-mta-aro}"
export RUN_ANSIBLE="${RUN_ANSIBLE:-false}"

# Determine region: use existing resource group location if exists, otherwise use specified or default
if [ -z "${AZURE_REGION:-}" ]; then
  # Check if resource group exists and get its location
  RG_LOCATION=$(az group show --name "$AZURE_RESOURCE_GROUP" --query location -o tsv 2>/dev/null || echo "")
  if [ -n "$RG_LOCATION" ]; then
    export AZURE_REGION="$RG_LOCATION"
    echo -e "${GREEN}Using existing resource group location: $AZURE_REGION${NC}"
  else
    # Use Azure CLI default location or japaneast as fallback
    AZURE_CLI_LOCATION=$(az account show --query location -o tsv 2>/dev/null || echo "")
    export AZURE_REGION="${AZURE_CLI_LOCATION:-japaneast}"
    echo -e "${GREEN}Using region: $AZURE_REGION${NC}"
  fi
fi

echo -e "${GREEN}Starting deployment...${NC}"
echo "Resource Group: $AZURE_RESOURCE_GROUP"
echo "Region: $AZURE_REGION"
echo "Cluster Name: $ARO_CLUSTER_NAME"

# Determine whether to skip network phase
if [ -z "${NETWORK_SKIP:-}" ]; then
  if az network vnet show -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_VNET_NAME" &> /dev/null; then
    NETWORK_SKIP="true"
  else
    NETWORK_SKIP="false"
  fi
fi

if [ "$NETWORK_SKIP" = "true" ]; then
  echo -e "${GREEN}Network exists. Skipping network phase.${NC}"

  RESOURCE_GROUP_NAME="$AZURE_RESOURCE_GROUP"
  LOCATION=$(az group show --name "$AZURE_RESOURCE_GROUP" --query location -o tsv)
  VNET_ID=$(az network vnet show -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_VNET_NAME" --query id -o tsv)
  MASTER_SUBNET_ID=$(az network vnet subnet show -g "$AZURE_RESOURCE_GROUP" --vnet-name "$AZURE_VNET_NAME" -n "aro-master-subnet" --query id -o tsv)
  WORKER_SUBNET_ID=$(az network vnet subnet show -g "$AZURE_RESOURCE_GROUP" --vnet-name "$AZURE_VNET_NAME" -n "aro-worker-subnet" --query id -o tsv)

  echo "Network Phase Skipped:"
  echo "  Resource Group: $RESOURCE_GROUP_NAME"
  echo "  Location: $LOCATION"
  echo "  VNet ID: $VNET_ID"
  echo "  Master Subnet ID: $MASTER_SUBNET_ID"
  echo "  Worker Subnet ID: $WORKER_SUBNET_ID"
else
  # Phase 1: Network
  echo -e "${GREEN}=== Phase 1: Network Infrastructure ===${NC}"
  cd terraform/network

# Resolve ARO RP Service Principal client ID if not provided
if [ -z "${ARO_RP_CLIENT_ID:-}" ]; then
  ARO_RP_CLIENT_ID=$(az ad sp list --filter "displayName eq 'Azure Red Hat OpenShift RP'" --query "[0].appId" -o tsv 2>/dev/null || echo "")
  if [ -n "$ARO_RP_CLIENT_ID" ]; then
    echo -e "${GREEN}Resolved ARO RP client ID from Azure AD: $ARO_RP_CLIENT_ID${NC}"
  else
    echo -e "${YELLOW}Warning: Could not resolve ARO RP client ID from Azure AD. Using Terraform default.${NC}"
  fi
fi

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Check if resource group exists
RG_EXISTS=$(az group show --name "$AZURE_RESOURCE_GROUP" --query name -o tsv 2>/dev/null || echo "")
if [ -n "$RG_EXISTS" ]; then
  RESOURCE_GROUP_CREATE="false"
  echo -e "${GREEN}Resource group '$AZURE_RESOURCE_GROUP' already exists, will use existing location${NC}"
else
  RESOURCE_GROUP_CREATE="true"
  echo -e "${GREEN}Resource group '$AZURE_RESOURCE_GROUP' will be created in '$AZURE_REGION'${NC}"
fi

# Create terraform.tfvars from environment variables
cat > terraform.tfvars <<EOF
resource_group_name = "$AZURE_RESOURCE_GROUP"
resource_group_create = $RESOURCE_GROUP_CREATE
location            = "$AZURE_REGION"
vnet_name           = "${AZURE_VNET_NAME:-aro-vnet}"
vnet_address_space  = ["10.0.0.0/16"]
master_subnet_name              = "aro-master-subnet"
master_subnet_address_prefixes  = ["10.0.1.0/24"]
worker_subnet_name              = "aro-worker-subnet"
worker_subnet_address_prefixes  = ["10.0.2.0/24"]
tags = {
  Environment = "development"
  Project     = "mta-workshop"
}
EOF

# Add ARO RP client ID if resolved
if [ -n "${ARO_RP_CLIENT_ID:-}" ]; then
    echo "aro_rp_service_principal_client_id = \"$ARO_RP_CLIENT_ID\"" >> terraform.tfvars
fi

# Plan and apply (auto-approve for deployment)
echo "Planning Terraform changes..."
terraform plan -out=tfplan

echo "Applying Terraform changes (auto-approve)..."
terraform apply -auto-approve tfplan

# Get outputs
echo "Getting network outputs..."
RESOURCE_GROUP_NAME=$(terraform output -raw resource_group_name)
LOCATION=$(terraform output -raw resource_group_location)
VNET_ID=$(terraform output -raw vnet_id)
MASTER_SUBNET_ID=$(terraform output -raw master_subnet_id)
WORKER_SUBNET_ID=$(terraform output -raw worker_subnet_id)

echo "Network Phase Complete:"
echo "  Resource Group: $RESOURCE_GROUP_NAME"
echo "  Location: $LOCATION"
echo "  VNet ID: $VNET_ID"
echo "  Master Subnet ID: $MASTER_SUBNET_ID"
echo "  Worker Subnet ID: $WORKER_SUBNET_ID"
fi

# Phase 2: ARO Cluster
echo -e "${GREEN}=== Phase 2: ARO Cluster ===${NC}"
if [ "$NETWORK_SKIP" != "true" ]; then
  cd ../cluster
else
  cd "$SCRIPT_DIR/terraform/cluster"
fi

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Generate domain from GUID if not provided
if [ -z "${ARO_DOMAIN:-}" ]; then
  if [ -n "${GUID:-}" ]; then
    # Use first 8 characters of GUID (remove hyphens and take first 8)
    DOMAIN_SUFFIX=$(echo "$GUID" | tr -d '-' | cut -c1-8)
    ARO_DOMAIN="${DOMAIN_SUFFIX}"
    echo -e "${GREEN}Generated domain from GUID: $ARO_DOMAIN${NC}"
  else
    # Generate random 8 characters if GUID is not available
    ARO_DOMAIN=$(openssl rand -hex 4 2>/dev/null || echo $(head -c 4 /dev/urandom | xxd -p))
    echo -e "${YELLOW}GUID not found, generated random domain: $ARO_DOMAIN${NC}"
  fi
fi

# Create terraform.tfvars from environment variables and Phase 1 outputs
cat > terraform.tfvars <<EOF
resource_group_name = "$RESOURCE_GROUP_NAME"
location            = "$LOCATION"
vnet_id             = "$VNET_ID"
master_subnet_id    = "$MASTER_SUBNET_ID"
worker_subnet_id    = "$WORKER_SUBNET_ID"

cluster_name = "$ARO_CLUSTER_NAME"
domain       = "$ARO_DOMAIN"
ocp_version  = "${ARO_OCP_VERSION:-4.19.20}"

master_vm_size   = "${ARO_MASTER_VM_SIZE:-Standard_D8s_v3}"
master_disk_size = 128
worker_vm_size   = "${ARO_WORKER_VM_SIZE:-Standard_D4s_v3}"
worker_disk_size = 128
worker_count     = ${ARO_WORKER_COUNT:-3}

pod_cidr     = "${ARO_POD_CIDR:-10.128.0.0/14}"
service_cidr = "${ARO_SERVICE_CIDR:-172.30.0.0/16}"

tags = {
  Environment = "development"
  Project     = "mta-workshop"
}
EOF

# Add Service Principal client secret (required)
if [ -n "${ARM_CLIENT_SECRET:-}" ]; then
    echo "service_principal_client_secret = \"$ARM_CLIENT_SECRET\"" >> terraform.tfvars
else
    echo -e "${RED}Error: ARM_CLIENT_SECRET (or PASSWORD) is required for ARO cluster creation${NC}"
    exit 1
fi

# Add pull secret if provided
# Support both ARO_PULL_SECRET_FILE (file path) and ARO_PULL_SECRET (direct content)
if [ -n "${ARO_PULL_SECRET_FILE:-}" ]; then
    # Read pull secret from file
    if [ -f "$ARO_PULL_SECRET_FILE" ]; then
        echo -e "${GREEN}Reading pull secret from file: $ARO_PULL_SECRET_FILE${NC}"
        # Read file content and convert to single line JSON (escape newlines and quotes)
        PULL_SECRET_CONTENT=$(cat "$ARO_PULL_SECRET_FILE" | jq -c . 2>/dev/null || cat "$ARO_PULL_SECRET_FILE" | tr -d '\n' | sed 's/"/\\"/g')
        # Use heredoc format for multi-line support in terraform.tfvars
        cat >> terraform.tfvars <<EOF
pull_secret = <<-EOT
$(cat "$ARO_PULL_SECRET_FILE")
EOT
EOF
    else
        echo -e "${RED}Error: Pull secret file not found: $ARO_PULL_SECRET_FILE${NC}"
        exit 1
    fi
elif [ -n "${ARO_PULL_SECRET:-}" ]; then
    # Use pull secret content directly
    echo -e "${GREEN}Using pull secret from ARO_PULL_SECRET environment variable${NC}"
    # Convert to single line if it's JSON, or use as-is
    PULL_SECRET_CONTENT=$(echo "$ARO_PULL_SECRET" | jq -c . 2>/dev/null || echo "$ARO_PULL_SECRET")
    # Use heredoc format for multi-line support
    cat >> terraform.tfvars <<EOF
pull_secret = <<-EOT
$ARO_PULL_SECRET
EOT
EOF
else
    echo -e "${YELLOW}Warning: No pull secret provided. OperatorHub may not be available.${NC}"
    echo -e "${YELLOW}To enable OperatorHub, set ARO_PULL_SECRET_FILE or ARO_PULL_SECRET in env.sh${NC}"
fi

# Plan and apply (auto-approve for deployment)
echo "Planning Terraform changes..."
terraform plan -out=tfplan

echo "Applying Terraform changes (this may take 30-60 minutes, auto-approve)..."
terraform apply -auto-approve tfplan

# Get cluster outputs from Azure (authoritative)
echo "Getting cluster outputs..."

# Ensure RESOURCE_GROUP_NAME is set (fallback to AZURE_RESOURCE_GROUP if not set)
if [ -z "${RESOURCE_GROUP_NAME:-}" ]; then
  RESOURCE_GROUP_NAME="$AZURE_RESOURCE_GROUP"
  echo -e "${YELLOW}Warning: RESOURCE_GROUP_NAME not set, using AZURE_RESOURCE_GROUP: $RESOURCE_GROUP_NAME${NC}"
fi

# Ensure LOCATION is set (fallback to AZURE_REGION if not set)
if [ -z "${LOCATION:-}" ]; then
  LOCATION="${AZURE_REGION:-eastus}"
  echo -e "${YELLOW}Warning: LOCATION not set, using AZURE_REGION: $LOCATION${NC}"
fi

CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "$ARO_CLUSTER_NAME")
API_SERVER_URL=$(az aro show --name "$ARO_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query apiserverProfile.url -o tsv 2>/dev/null || echo "")
CONSOLE_URL=$(az aro show --name "$ARO_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query consoleProfile.url -o tsv 2>/dev/null || echo "")

if [ -z "$API_SERVER_URL" ] || [ -z "$CONSOLE_URL" ]; then
  echo -e "${RED}Error: Failed to get cluster URLs. Please check if cluster exists.${NC}"
  exit 1
fi

echo "Cluster Phase Complete:"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  API Server URL: $API_SERVER_URL"
echo "  Console URL: $CONSOLE_URL"

# Wait for cluster to be ready
echo -e "${GREEN}Waiting for cluster to be ready...${NC}"
echo "This may take a few minutes..."

max_attempts=60
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if az aro show --name "$ARO_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query "provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; then
        echo -e "${GREEN}Cluster is ready!${NC}"
        break
    fi
    attempt=$((attempt + 1))
    echo "Waiting... ($attempt/$max_attempts)"
    sleep 10
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${YELLOW}Warning: Cluster may still be provisioning. Continuing...${NC}"
fi

# Wait for API DNS to resolve
echo -e "${GREEN}Waiting for API DNS to resolve...${NC}"
if [ -z "${API_SERVER_URL:-}" ]; then
  echo -e "${RED}Error: API_SERVER_URL is not set${NC}"
  exit 1
fi

api_host=$(echo "$API_SERVER_URL" | awk -F'[/:]' '{print $4}')
dns_attempts=60
dns_attempt=0
dns_resolved=false

while [ $dns_attempt -lt $dns_attempts ]; do
  # Try DNS resolution using nslookup (more portable than python3)
  if nslookup "$api_host" >/dev/null 2>&1 || getent hosts "$api_host" >/dev/null 2>&1; then
    echo -e "${GREEN}API DNS resolved: $api_host${NC}"
    dns_resolved=true
    break
  fi
  dns_attempt=$((dns_attempt + 1))
  if [ $((dns_attempt % 6)) -eq 0 ]; then
    echo "Waiting for DNS... ($dns_attempt/$dns_attempts)"
  fi
  sleep 10
done

if [ "$dns_resolved" = "false" ]; then
  echo -e "${YELLOW}Warning: DNS resolution timeout after $((dns_attempts * 10)) seconds. Continuing anyway...${NC}"
fi

# Get cluster credentials
echo -e "${GREEN}Getting cluster credentials...${NC}"
CREDENTIALS=$(az aro list-credentials --name "$ARO_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP_NAME" -o json)
ADMIN_USERNAME=$(echo "$CREDENTIALS" | jq -r '.kubeadminUsername')
ADMIN_PASSWORD=$(echo "$CREDENTIALS" | jq -r '.kubeadminPassword')

echo "Cluster credentials retrieved:"
echo "  Admin Username: $ADMIN_USERNAME"
echo "  Admin Password: $ADMIN_PASSWORD"

# Test cluster access
echo -e "${GREEN}Testing cluster access...${NC}"
if oc login "$API_SERVER_URL" -u "$ADMIN_USERNAME" -p "$ADMIN_PASSWORD" --insecure-skip-tls-verify &> /dev/null; then
    echo -e "${GREEN}Successfully connected to cluster!${NC}"
    oc whoami
else
    echo -e "${YELLOW}Warning: Could not connect to cluster. You may need to wait longer.${NC}"
fi

# Generate cluster_info.json for Ansible
echo -e "${GREEN}Generating cluster_info.json for Ansible...${NC}"
cd "$SCRIPT_DIR"
mkdir -p ansible/inventory

cat > ansible/inventory/cluster_info.json <<EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "api_server_url": "$API_SERVER_URL",
  "console_url": "$CONSOLE_URL",
  "admin_username": "$ADMIN_USERNAME",
  "admin_password": "$ADMIN_PASSWORD",
  "resource_group": "$RESOURCE_GROUP_NAME",
  "location": "$LOCATION"
}
EOF

echo "cluster_info.json created at ansible/inventory/cluster_info.json"

# Debug: Show RUN_ANSIBLE value
echo -e "${YELLOW}DEBUG: RUN_ANSIBLE=${RUN_ANSIBLE:-not set}${NC}"

# Run Ansible if requested
if [ "${RUN_ANSIBLE:-false}" = "true" ]; then
    echo -e "${GREEN}=== Running Ansible Playbook ===${NC}"
    cd ansible
    
    if [ -f "site.yml" ]; then
        ansible-playbook -i inventory/cluster_info.json site.yml
        echo -e "${GREEN}Ansible playbook completed!${NC}"
    else
        echo -e "${YELLOW}Warning: site.yml not found. Skipping Ansible execution.${NC}"
    fi
else
    echo -e "${YELLOW}Skipping Ansible execution (RUN_ANSIBLE=false)${NC}"
fi

echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo "Cluster Console: $CONSOLE_URL"
echo "API Server: $API_SERVER_URL"
echo ""
echo "To access the cluster:"
echo "  oc login $API_SERVER_URL -u $ADMIN_USERNAME -p [password] --insecure-skip-tls-verify"
