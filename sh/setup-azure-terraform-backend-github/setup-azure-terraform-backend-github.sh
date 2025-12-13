#!/bin/bash

#===============================================================================
# setup-azure-terraform-backend-github.sh
#
# Creates Azure Storage Account for Terraform state and configures GitHub Secrets.
#
# FEATURES:
# - Interactive Azure Subscription selection
# - Interactive GitHub Org/Repo/Environment selection
# - Interactive App Registration selection (for access)
# - Idempotent resource creation (RG, Storage, Container)
# - Security best practices (TLS 1.2, No Public Access, Soft Delete)
# - GitHub Secrets configuration (Overwrites existing)
#
# USAGE:
#   ./setup-azure-terraform-backend-github.sh
#
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
RESOURCE_GROUP=""
LOCATION=""
STORAGE_ACCOUNT=""
CONTAINER_NAME="tfstate"
APP_ID=""
APP_NAME=""
GITHUB_ORG=""
GITHUB_REPO=""
ENVIRONMENT=""
AUTO_CONFIRM=false

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() { echo -e "${CYAN}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

prompt() {
    local VAR_NAME=$1
    local PROMPT_TEXT=$2
    local DEFAULT_VALUE=$3
    local CURRENT_VALUE=${!VAR_NAME}
    
    # If already set via parameter, skip prompt
    if [[ -n "$CURRENT_VALUE" ]]; then
        return
    fi
    
    if [[ -n "$DEFAULT_VALUE" ]]; then
        read -p "$PROMPT_TEXT [$DEFAULT_VALUE]: " INPUT
        eval "$VAR_NAME=\"${INPUT:-$DEFAULT_VALUE}\""
    else
        read -p "$PROMPT_TEXT: " INPUT
        eval "$VAR_NAME=\"$INPUT\""
    fi
}

select_from_list() {
    local VAR_NAME=$1
    local PROMPT_TEXT=$2
    local LIST_CMD=$3
    local CURRENT_VALUE=${!VAR_NAME}

    if [[ -n "$CURRENT_VALUE" ]]; then
        return
    fi

    echo "$PROMPT_TEXT"
    
    local ITEMS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && ITEMS+=("$line")
    done < <(eval "$LIST_CMD")

    if [[ ${#ITEMS[@]} -eq 0 ]]; then
        echo "No items found."
        read -p "Enter manual value: " MANUAL_VAL
        eval "$VAR_NAME=\"$MANUAL_VAL\""
        return
    fi

    local i=1
    for item in "${ITEMS[@]}"; do
        echo "  $i) $item"
        ((i++))
    done
    echo "  0) Manual Input"

    local SELECTION
    while true; do
        read -p "Select [1-${#ITEMS[@]}]: " SELECTION
        if [[ "$SELECTION" == "0" ]]; then
            read -p "Enter manual value: " MANUAL_VAL
            eval "$VAR_NAME=\"$MANUAL_VAL\""
            break
        elif [[ "$SELECTION" =~ ^[0-9]+$ ]] && (( SELECTION >= 1 && SELECTION <= ${#ITEMS[@]} )); then
            eval "$VAR_NAME=\"${ITEMS[$((SELECTION-1))]}\""
            break
        else
            echo "Invalid selection."
        fi
    done
}

confirm() {
    local PROMPT_TEXT=$1
    if [[ "$AUTO_CONFIRM" == true ]]; then
        return 0
    fi
    read -p "$PROMPT_TEXT (y/n): " RESPONSE
    [[ "$RESPONSE" == "y" || "$RESPONSE" == "Y" ]]
}

#-------------------------------------------------------------------------------
# Prerequisites
#-------------------------------------------------------------------------------

print_header "Prerequisites Check"

if ! command -v az &> /dev/null; then
    print_error "Azure CLI not installed"
    exit 1
fi

if ! command -v gh &> /dev/null; then
    print_error "GitHub CLI not installed"
    exit 1
fi

if ! az account show &> /dev/null; then
    print_error "Not logged in to Azure. Run 'az login' first."
    exit 1
fi

if ! gh auth status &> /dev/null; then
    print_error "Not logged in to GitHub. Run 'gh auth login' first."
    exit 1
fi

print_success "Prerequisites met"

#-------------------------------------------------------------------------------
# Azure Context (Subscription)
#-------------------------------------------------------------------------------

print_header "Azure Subscription"

if [[ -z "$SUBSCRIPTION" ]]; then
    echo "Available subscriptions:"
    az account list --query "[].{Name:name, ID:id, Default:isDefault}" -o table
    echo ""
fi

prompt SUBSCRIPTION "Enter subscription ID or name (empty for current)" ""

if [[ -n "$SUBSCRIPTION" ]]; then
    az account set --subscription "$SUBSCRIPTION"
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo -e "Selected: ${GREEN}$SUBSCRIPTION_NAME${NC}"

#-------------------------------------------------------------------------------
# GitHub Context
#-------------------------------------------------------------------------------

print_header "GitHub Configuration"

# Select Org
select_from_list GITHUB_ORG "Select GitHub Organization or User:" \
    "{ gh api user -q .login; gh org list --json login -q '.[].login'; }"

# Select Repo
select_from_list GITHUB_REPO "Select Repository from $GITHUB_ORG:" \
    "gh repo list $GITHUB_ORG --limit 30 --json name -q '.[].name'"

GITHUB_REPO_FULL="$GITHUB_ORG/$GITHUB_REPO"

# Select Environment
echo "Fetching environments for $GITHUB_REPO_FULL..."
select_from_list ENVIRONMENT "Select Environment for secrets:" \
    "gh api \"repos/$GITHUB_REPO_FULL/environments\" --jq '.environments[].name' 2>/dev/null"

if [[ -z "$ENVIRONMENT" ]]; then
    prompt ENVIRONMENT "Environment name" "production"
fi

#-------------------------------------------------------------------------------
# App Registration Selection
#-------------------------------------------------------------------------------

print_header "App Registration (Service Principal)"
echo "Select the App Registration to use for 'AZURE_CLIENT_ID' and grant storage access."

# We list apps, but showing display name and appId might be useful.
# select_from_list is simple, so let's list DisplayNames and then resolve ID.
# Or list "DisplayName|AppId" strings.

select_from_list APP_SELECTION "Select App Registration:" \
    "az ad app list --filter \"startswith(displayName, 'GitHub')\" --query \"[].{Name:displayName, AppId:appId}\" -o tsv | awk '{print \$1 \"|\" \$2}'"

if [[ -z "$APP_SELECTION" ]]; then
    # Fallback to listing all or manual
    prompt APP_ID "Enter App Registration Client ID (Application ID)" ""
else
    # Extract App ID from "Name|AppID" format safely
    IFS='|' read -r APP_NAME APP_ID <<< "$APP_SELECTION"
fi

if [[ -z "$APP_ID" ]]; then
    print_error "App ID is required."
    exit 1
fi

print_success "Selected App ID: $APP_ID"

#-------------------------------------------------------------------------------
# Resource Configuration
#-------------------------------------------------------------------------------

print_header "Terraform Backend Resources"

# Select Resource Group
select_from_list RESOURCE_GROUP "Select Resource Group (or enter new name):" \
    "az group list --query \"[].name\" -o tsv | sort"

# If manual input was used in select_from_list or param was passed, it is already set.
if [[ -z "$RESOURCE_GROUP" ]]; then
    prompt RESOURCE_GROUP "Resource Group Name" "rg-terraform-state"
fi

# Select Storage Account based on RG
print_header "Storage Account Selection"
echo "Fetching storage accounts in $RESOURCE_GROUP..."

select_from_list STORAGE_ACCOUNT "Select Storage Account (or enter new name):" \
    "az storage account list --resource-group \"$RESOURCE_GROUP\" --query \"[].name\" -o tsv 2>/dev/null | sort"

# Generate random suffix for default if needed
RANDOM_SUFFIX=$(echo $RANDOM | md5sum | head -c 8)

if [[ -z "$STORAGE_ACCOUNT" ]]; then
    prompt STORAGE_ACCOUNT "Storage Account Name (unique)" "sttf${RANDOM_SUFFIX}"
    NEW_STORAGE_NEEDED=true
else
    # Check if it actually exists (in case user manually entered a name that doesn't exist)
    if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
        print_success "Selected existing storage account: $STORAGE_ACCOUNT"
        NEW_STORAGE_NEEDED=false
    else
        print_warning "Storage account '$STORAGE_ACCOUNT' does not exist in '$RESOURCE_GROUP'. It will be created."
        NEW_STORAGE_NEEDED=true
    fi
fi

if [[ "$NEW_STORAGE_NEEDED" == true ]]; then
    prompt LOCATION "Azure Region" "eastus"
else
    # Get location from existing account
    LOCATION=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query location -o tsv)
    echo "Location: $LOCATION (from existing account)"
fi

prompt CONTAINER_NAME "Container Name" "tfstate"

#-------------------------------------------------------------------------------
# Summary & Confirmation
#-------------------------------------------------------------------------------

print_header "Configuration Summary"

echo "Azure Subscription: $SUBSCRIPTION_NAME"
echo "GitHub Repo:        $GITHUB_REPO_FULL"
echo "Environment:        $ENVIRONMENT"
echo "App Registration:   $APP_ID"
echo ""
echo "Resources to Create/Configure:"
echo "  Resource Group:   $RESOURCE_GROUP"
echo "  Location:         $LOCATION"
echo "  Storage Account:  $STORAGE_ACCOUNT (Standard_LRS, No Public Access)"
echo "  Container:        $CONTAINER_NAME"
echo ""

if ! confirm "Proceed with setup?"; then
    print_warning "Cancelled"
    exit 0
fi

#-------------------------------------------------------------------------------
# Execution
#-------------------------------------------------------------------------------

print_header "Executing Setup"

# 1. Resource Group
print_step "Checking Resource Group..."
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    print_warning "Resource Group '$RESOURCE_GROUP' already exists."
else
    print_step "Creating Resource Group '$RESOURCE_GROUP'..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
    print_success "Resource Group created."
fi

# 2. Storage Account
print_step "Checking Storage Account..."
if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    print_warning "Storage Account '$STORAGE_ACCOUNT' already exists."
else
    print_step "Creating Storage Account '$STORAGE_ACCOUNT'..."
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --https-only true \
        --min-tls-version TLS1_2 \
        --allow-blob-public-access false \
        --allow-shared-key-access true \
        --output none
    print_success "Storage Account created."
fi

# Enable Versioning & Soft Delete (Idempotent updates)
print_step "Configuring Storage properties (Versioning, Soft Delete)..."
az storage account blob-service-properties update \
    --account-name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --enable-versioning true \
    --delete-retention-days 7 \
    --enable-delete-retention true \
    --output none
print_success "Storage properties configured."

# 3. Container
print_step "Checking Container..."
# Note: We use auth-mode login to avoid needing keys right here if we have permissions, 
# but usually the creator is owner.
if az storage container show --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT" --auth-mode login &>/dev/null; then
    print_warning "Container '$CONTAINER_NAME' already exists."
else
    print_step "Creating Container '$CONTAINER_NAME'..."
    az storage container create \
        --name "$CONTAINER_NAME" \
        --account-name "$STORAGE_ACCOUNT" \
        --auth-mode login \
        --output none
    print_success "Container created."
fi

# 4. Grant Access
print_step "Granting 'Storage Blob Data Contributor' to App ID..."
# Check existing assignment to avoid error
EXISTING_ASSIGNMENT=$(az role assignment list \
    --assignee "$APP_ID" \
    --role "Storage Blob Data Contributor" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT" \
    --query "[].id" -o tsv)

if [[ -n "$EXISTING_ASSIGNMENT" ]]; then
    print_warning "Role assignment already exists."
else
    az role assignment create \
        --assignee "$APP_ID" \
        --role "Storage Blob Data Contributor" \
        --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT" \
        --output none
    print_success "Role assigned."
fi

# 5. GitHub Secrets
print_header "Configuring GitHub Secrets"

# Ensure environment exists
echo '{"wait_timer":0}' | gh api "repos/$GITHUB_REPO_FULL/environments/$ENVIRONMENT" -X PUT --input - >/dev/null 2>&1 || true

set_secret() {
    local NAME=$1
    local VALUE=$2
    
    # Optional: Remove existing secret first if strictly required
    # gh secret delete "$NAME" --repo "$GITHUB_REPO_FULL" --env "$ENVIRONMENT" &>/dev/null || true
    
    echo -n "  Setting $NAME... "
    echo "$VALUE" | gh secret set "$NAME" --repo "$GITHUB_REPO_FULL" --env "$ENVIRONMENT"
    echo "Done"
}

set_secret "TF_BACKEND_RESOURCE_GROUP" "$RESOURCE_GROUP"
set_secret "TF_BACKEND_STORAGE_ACCOUNT" "$STORAGE_ACCOUNT"
set_secret "TF_BACKEND_CONTAINER" "$CONTAINER_NAME"
set_secret "TF_BACKEND_KEY" "terraform.tfstate"
set_secret "TF_BACKEND_SUBSCRIPTION_ID" "$SUBSCRIPTION_ID"
set_secret "TF_BACKEND_TENANT_ID" "$TENANT_ID"
set_secret "AZURE_SUBSCRIPTION_ID" "$SUBSCRIPTION_ID"
set_secret "AZURE_TENANT_ID" "$TENANT_ID"
set_secret "AZURE_CLIENT_ID" "$APP_ID"

print_success "Secrets configured in '$ENVIRONMENT' environment."

#-------------------------------------------------------------------------------
# Output Config File
#-------------------------------------------------------------------------------

# Resolve script directory to correctly locate the results folder regardless of execution path
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
OUTPUT_DIR="$PROJECT_ROOT/script-results/terraform-backend-config"

mkdir -p "$OUTPUT_DIR"
CONFIG_FILE="$OUTPUT_DIR/${ENVIRONMENT}-backend.tf"

cat > "$CONFIG_FILE" << EOF
terraform {
  backend "azurerm" {
    resource_group_name  = "$RESOURCE_GROUP"
    storage_account_name = "$STORAGE_ACCOUNT"
    container_name       = "$CONTAINER_NAME"
    key                  = "terraform.tfstate"
    subscription_id      = "$SUBSCRIPTION_ID"
    tenant_id            = "$TENANT_ID"
    use_oidc             = true
  }
}
EOF

echo ""
echo -e "${GREEN}Setup Complete!${NC}"
echo "Backend configuration saved to: $CONFIG_FILE"
echo "You can now initialize Terraform in your project."
