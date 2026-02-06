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
        
        # Destroy cluster (auto-approve)
        echo "Destroying ARO cluster (this may take 20-40 minutes, auto-approve)..."
        terraform apply -destroy -auto-approve tfplan
        
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
    
    # Check if resource group was created by Terraform
    RG_CREATED_BY_TERRAFORM=$(terraform state show -no-color azurerm_resource_group.main[0] 2>/dev/null | grep -q "azurerm_resource_group.main" && echo "yes" || echo "no")
    
    # Check if resource group was created by Terraform (by checking if resource_group_create was true)
    # We need to check the terraform.tfvars or state to see if resource_group_create was true
    RG_CREATED=$(terraform state list 2>/dev/null | grep -q "azurerm_resource_group.main" && echo "yes" || echo "no")
    
    # Plan destruction
    echo "Planning Terraform destruction..."
    terraform plan -destroy -out=tfplan
    
    # Destroy network (auto-approve)
    echo "Destroying network infrastructure (auto-approve)..."
    terraform apply -destroy -auto-approve tfplan
    
    # Note: If resource group was created by Terraform, it will be deleted automatically
    # If resource group was pre-existing, it will remain (as intended)
    if [ "$RG_CREATED" = "no" ]; then
        echo -e "${GREEN}Note: Resource group '$AZURE_RESOURCE_GROUP' was pre-existing and was not deleted.${NC}"
    fi
fi

echo -e "${GREEN}=== Destruction Complete ===${NC}"
echo "All resources have been destroyed."
