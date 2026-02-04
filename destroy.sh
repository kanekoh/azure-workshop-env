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
for cmd in terraform az; do
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
export ARO_CLUSTER_NAME="${ARO_CLUSTER_NAME:-mta-aro}"

echo -e "${RED}=== WARNING: This will destroy all resources ===${NC}"
echo "Resource Group: $AZURE_RESOURCE_GROUP"
echo "Cluster Name: $ARO_CLUSTER_NAME"
echo ""
echo -e "${YELLOW}This action cannot be undone!${NC}"
echo -e "${YELLOW}Do you want to continue? (yes/no)${NC}"
read -r response
if [ "$response" != "yes" ]; then
    echo "Destruction cancelled."
    exit 0
fi

# Phase 1: Destroy ARO Cluster
echo -e "${GREEN}=== Phase 1: Destroying ARO Cluster ===${NC}"
cd terraform/cluster

# Check if Terraform state exists
if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
    echo -e "${YELLOW}Warning: No Terraform state found for cluster. Skipping cluster destruction.${NC}"
else
    # Initialize Terraform if needed
    if [ ! -d ".terraform" ]; then
        echo "Initializing Terraform..."
        terraform init
    fi

    # Check if cluster exists
    if az aro show --name "$ARO_CLUSTER_NAME" --resource-group "$AZURE_RESOURCE_GROUP" &> /dev/null; then
        echo "Cluster exists. Proceeding with destruction..."
        
        # Plan destruction
        echo "Planning Terraform destruction..."
        terraform plan -destroy -out=tfplan
        
        echo -e "${YELLOW}Do you want to proceed with cluster destruction? (yes/no)${NC}"
        read -r response
        if [ "$response" != "yes" ]; then
            echo "Cluster destruction cancelled."
            exit 0
        fi
        
        # Destroy cluster
        echo "Destroying ARO cluster (this may take 20-40 minutes)..."
        terraform apply -destroy tfplan
        
        # Wait for cluster deletion to complete
        echo -e "${GREEN}Waiting for cluster deletion to complete...${NC}"
        max_attempts=120
        attempt=0
        while [ $attempt -lt $max_attempts ]; do
            if ! az aro show --name "$ARO_CLUSTER_NAME" --resource-group "$AZURE_RESOURCE_GROUP" &> /dev/null; then
                echo -e "${GREEN}Cluster deletion completed!${NC}"
                break
            fi
            attempt=$((attempt + 1))
            echo "Waiting for cluster deletion... ($attempt/$max_attempts)"
            sleep 10
        done
        
        if [ $attempt -eq $max_attempts ]; then
            echo -e "${YELLOW}Warning: Cluster deletion may still be in progress. Continuing with network destruction...${NC}"
        fi
    else
        echo -e "${YELLOW}Cluster not found. Skipping cluster destruction.${NC}"
    fi
fi

# Phase 2: Destroy Network
echo -e "${GREEN}=== Phase 2: Destroying Network Infrastructure ===${NC}"
cd ../network

# Check if Terraform state exists
if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
    echo -e "${YELLOW}Warning: No Terraform state found for network. Skipping network destruction.${NC}"
else
    # Initialize Terraform if needed
    if [ ! -d ".terraform" ]; then
        echo "Initializing Terraform..."
        terraform init
    fi
    
    # Plan destruction
    echo "Planning Terraform destruction..."
    terraform plan -destroy -out=tfplan
    
    echo -e "${YELLOW}Do you want to proceed with network destruction? (yes/no)${NC}"
    read -r response
    if [ "$response" != "yes" ]; then
        echo "Network destruction cancelled."
        exit 0
    fi
    
    # Destroy network
    echo "Destroying network infrastructure..."
    terraform apply -destroy tfplan
fi

echo -e "${GREEN}=== Destruction Complete ===${NC}"
echo "All resources have been destroyed."
