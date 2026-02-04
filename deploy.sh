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
  # If TENANT is a domain name, try to get tenant ID from Azure CLI
  if [[ ! "$TENANT" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    # It's a domain name, get tenant ID from Azure
    TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null || echo "")
    if [ -n "$TENANT_ID" ]; then
      export ARM_TENANT_ID="$TENANT_ID"
    else
      echo -e "${YELLOW}Warning: Could not resolve tenant domain to ID. Using domain name as-is.${NC}"
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

# Check Azure CLI authentication
echo -e "${GREEN}Checking Azure CLI authentication...${NC}"
if ! az account show &> /dev/null; then
    echo -e "${YELLOW}Warning: Azure CLI is not authenticated. Please run 'az login'${NC}"
    exit 1
fi

# Set default values if not set
export AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${RESOURCEGROUP:-aro-rg}}"
export AZURE_REGION="${AZURE_REGION:-japaneast}"
export ARO_CLUSTER_NAME="${ARO_CLUSTER_NAME:-mta-aro}"
export RUN_ANSIBLE="${RUN_ANSIBLE:-false}"

echo -e "${GREEN}Starting deployment...${NC}"
echo "Resource Group: $AZURE_RESOURCE_GROUP"
echo "Region: $AZURE_REGION"
echo "Cluster Name: $ARO_CLUSTER_NAME"

# Phase 1: Network
echo -e "${GREEN}=== Phase 1: Network Infrastructure ===${NC}"
cd terraform/network

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Create terraform.tfvars from environment variables
cat > terraform.tfvars <<EOF
resource_group_name = "$AZURE_RESOURCE_GROUP"
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

# Plan and apply
echo "Planning Terraform changes..."
terraform plan -out=tfplan

echo -e "${YELLOW}Do you want to apply these changes? (yes/no)${NC}"
read -r response
if [ "$response" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

echo "Applying Terraform changes..."
terraform apply tfplan

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

# Phase 2: ARO Cluster
echo -e "${GREEN}=== Phase 2: ARO Cluster ===${NC}"
cd ../cluster

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Create terraform.tfvars from environment variables and Phase 1 outputs
cat > terraform.tfvars <<EOF
resource_group_name = "$RESOURCE_GROUP_NAME"
location            = "$LOCATION"
vnet_id             = "$VNET_ID"
master_subnet_id    = "$MASTER_SUBNET_ID"
worker_subnet_id    = "$WORKER_SUBNET_ID"

cluster_name = "$ARO_CLUSTER_NAME"
domain       = "${ARO_DOMAIN:-}"
ocp_version  = "${ARO_OCP_VERSION:-4.14}"

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

# Add pull secret if provided
if [ -n "${ARO_PULL_SECRET:-}" ]; then
    echo "pull_secret = \"$ARO_PULL_SECRET\"" >> terraform.tfvars
fi

# Plan and apply
echo "Planning Terraform changes..."
terraform plan -out=tfplan

echo -e "${YELLOW}Do you want to apply these changes? This will create the ARO cluster. (yes/no)${NC}"
read -r response
if [ "$response" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

echo "Applying Terraform changes (this may take 30-60 minutes)..."
terraform apply tfplan

# Get cluster outputs
echo "Getting cluster outputs..."
CLUSTER_NAME=$(terraform output -raw cluster_name)
API_SERVER_URL=$(terraform output -raw api_server_url)
CONSOLE_URL=$(terraform output -raw console_url)

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

# Get cluster credentials
echo -e "${GREEN}Getting cluster credentials...${NC}"
CREDENTIALS=$(az aro list-credentials --name "$ARO_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP_NAME" -o json)
ADMIN_USERNAME=$(echo "$CREDENTIALS" | jq -r '.kubeadminUsername')
ADMIN_PASSWORD=$(echo "$CREDENTIALS" | jq -r '.kubeadminPassword')

echo "Cluster credentials retrieved:"
echo "  Admin Username: $ADMIN_USERNAME"
echo "  Admin Password: [hidden]"

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

# Run Ansible if requested
if [ "$RUN_ANSIBLE" = "true" ]; then
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
