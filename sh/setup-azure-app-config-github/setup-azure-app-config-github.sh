#!/bin/bash

#===============================================================================
# setup-azure-app-config-github.sh
#
# Configures Azure App Configuration access for GitHub Actions/Terraform.
#
# FEATURES:
# - Interactive Azure Subscription selection
# - Grants Service Principal 'Owner' access to Subscription
# - Selects existing or creates new Azure App Configuration
# - Grants 'App Configuration Data Owner' for data plane access
# - Configures GitHub Secrets with Resource ID
#
# USAGE:
#   ./setup-azure-app-config-github.sh
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
APP_CONFIG_NAME=""
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
    echo "  0) Manual Input/Create New"

    local SELECTION
    while true; do
        read -p "Select [1-${#ITEMS[@]}]: " SELECTION
        if [[ "$SELECTION" == "0" ]]; then
            read -p "Enter manual value (or leave empty to trigger creation flow if applicable): " MANUAL_VAL
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
# App Registration Selection
#-------------------------------------------------------------------------------

print_header "App Registration (Service Principal)"
echo "Select the App Registration to grant access."

select_from_list APP_SELECTION "Select App Registration:" \
    "az ad app list --filter \"startswith(displayName, 'GitHub')\" --query \"[].{Name:displayName, AppId:appId}\" -o tsv | awk '{print \$1 \"|\" \$2}'"

if [[ -z "$APP_SELECTION" ]]; then
    prompt APP_ID "Enter App Registration Client ID (Application ID)" ""
else
    IFS='|' read -r APP_NAME APP_ID <<< "$APP_SELECTION"
fi

if [[ -z "$APP_ID" ]]; then
    print_error "App ID is required."
    exit 1
fi

print_success "Selected App ID: $APP_ID"

#-------------------------------------------------------------------------------
# Grant Subscription Access
#-------------------------------------------------------------------------------

print_header "Granting Subscription Access"
print_step "Granting 'Owner' role on Subscription to Service Principal..."

EXISTING_OWNER=$(az role assignment list \
    --assignee "$APP_ID" \
    --role "Owner" \
    --scope "/subscriptions/$SUBSCRIPTION_ID" \
    --query "[].id" -o tsv)

if [[ -n "$EXISTING_OWNER" ]]; then
    print_warning "Role assignment 'Owner' already exists on subscription."
else
    if confirm "Assign 'Owner' role to $APP_ID on subscription $SUBSCRIPTION_NAME?"; then
        az role assignment create \
            --assignee "$APP_ID" \
            --role "Owner" \
            --scope "/subscriptions/$SUBSCRIPTION_ID" \
            --output none
        print_success "Role 'Owner' assigned on subscription."
    else
        print_warning "Skipped subscription role assignment."
    fi
fi

#-------------------------------------------------------------------------------
# App Configuration Resource
#-------------------------------------------------------------------------------

print_header "Azure App Configuration"

echo "Checking for existing App Configurations..."
select_from_list APP_CONFIG_NAME "Select App Configuration:" \
    "az appconfig list --query \"[].name\" -o tsv | sort"

CREATE_NEW=false
if [[ -z "$APP_CONFIG_NAME" ]]; then
    echo "No App Configuration selected or found."
    if confirm "Do you want to create a new App Configuration?"; then
        CREATE_NEW=true
        prompt APP_CONFIG_NAME "Enter new App Configuration Name (unique)" "appcs-${RANDOM}"
    else
        print_error "App Configuration is required."
        exit 1
    fi
else
    # Check if selected one exists (in case of manual input)
    if az appconfig show --name "$APP_CONFIG_NAME" &>/dev/null; then
        print_success "Selected existing App Configuration: $APP_CONFIG_NAME"
        RESOURCE_GROUP=$(az appconfig show --name "$APP_CONFIG_NAME" --query resourceGroup -o tsv)
    else
        print_warning "App Configuration '$APP_CONFIG_NAME' not found."
        if confirm "Create it?"; then
            CREATE_NEW=true
        else
            exit 1
        fi
    fi
fi

if [[ "$CREATE_NEW" == true ]]; then
    print_header "New Resource Configuration"
    
    # Resource Group Selection
    select_from_list RESOURCE_GROUP "Select Resource Group for App Config:" \
        "az group list --query \"[].name\" -o tsv | sort"
        
    if [[ -z "$RESOURCE_GROUP" ]]; then
        prompt RESOURCE_GROUP "Enter new Resource Group Name" "rg-app-config"
    fi

    # Check RG existence
    if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        print_step "Resource Group '$RESOURCE_GROUP' will be created."
        prompt LOCATION "Azure Region" "eastus"
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
        print_success "Resource Group created."
    else
        print_success "Using existing Resource Group: $RESOURCE_GROUP"
        if [[ -z "$LOCATION" ]]; then
             LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
        fi
    fi

    print_step "Creating App Configuration '$APP_CONFIG_NAME' in '$RESOURCE_GROUP'..."
    az appconfig create \
        --name "$APP_CONFIG_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard \
        --output none
    print_success "App Configuration created."
fi

# Get Resource ID
APP_CONFIG_ID=$(az appconfig show --name "$APP_CONFIG_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
APP_CONFIG_ENDPOINT=$(az appconfig show --name "$APP_CONFIG_NAME" --resource-group "$RESOURCE_GROUP" --query endpoint -o tsv)

print_success "App Configuration ID: $APP_CONFIG_ID"

#-------------------------------------------------------------------------------
# Grant Data Plane Access
#-------------------------------------------------------------------------------

print_header "Granting Data Plane Access"
# Grant 'App Configuration Data Owner' to allow reading/writing values via AAD
print_step "Granting 'App Configuration Data Owner' on App Configuration..."

EXISTING_DATA_OWNER=$(az role assignment list \
    --assignee "$APP_ID" \
    --role "App Configuration Data Owner" \
    --scope "$APP_CONFIG_ID" \
    --query "[].id" -o tsv)

if [[ -n "$EXISTING_DATA_OWNER" ]]; then
    print_warning "Role 'App Configuration Data Owner' already assigned."
else
    az role assignment create \
        --assignee "$APP_ID" \
        --role "App Configuration Data Owner" \
        --scope "$APP_CONFIG_ID" \
        --output none
    print_success "Role 'App Configuration Data Owner' assigned."
fi

#-------------------------------------------------------------------------------
# GitHub Configuration
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
# Set GitHub Secrets
#-------------------------------------------------------------------------------

print_header "Configuring GitHub Secrets"

# Ensure environment exists
echo '{"wait_timer":0}' | gh api "repos/$GITHUB_REPO_FULL/environments/$ENVIRONMENT" -X PUT --input - >/dev/null 2>&1 || true

set_secret() {
    local NAME=$1
    local VALUE=$2
    
    echo -n "  Setting $NAME... "
    echo "$VALUE" | gh secret set "$NAME" --repo "$GITHUB_REPO_FULL" --env "$ENVIRONMENT"
    echo "Done"
}

set_secret "AZURE_APP_CONFIG_RESOURCE_ID" "$APP_CONFIG_ID"
set_secret "AZURE_APP_CONFIG_NAME" "$APP_CONFIG_NAME"
set_secret "AZURE_APP_CONFIG_ENDPOINT" "$APP_CONFIG_ENDPOINT"
# Redundant but useful context
set_secret "AZURE_APP_CONFIG_RESOURCE_GROUP" "$RESOURCE_GROUP"

print_success "Secrets configured in '$ENVIRONMENT' environment."

echo ""
echo -e "${GREEN}Setup Complete!${NC}"
echo "You can now use these secrets in Terraform or Azure CLI."
echo "Example Terraform usage:"
echo "  resource \"azurerm_app_configuration_key\" \"example\" {"
echo "    configuration_store_id = \"\${var.app_config_resource_id}\""
echo "    key                    = \"my-key\""
echo "    value                  = \"my-value\""
echo "  }"
