#!/bin/bash

#===============================================================================
# Auth0-GitHub Connection Script
#
# Connects Auth0 M2M Applications to GitHub Repository Environments.
# Supports creating a single M2M app for all environments (Free Plan friendly)
# or one M2M app per environment.
#
# USAGE:
#   Interactive:    ./connect-auth0-github.sh
#   With params:    ./connect-auth0-github.sh [OPTIONS]
#
# OPTIONS:
#   -o, --github-org        GitHub organization or username
#   -r, --github-repo       GitHub repository name
#   -e, --environments      Comma-separated environments (e.g. dev,staging,prod)
#   -s, --strategy          App strategy: single | per-env
#   -d, --auth0-domain      Auth0 Domain (e.g. mytenant.auth0.com)
#   -y, --auto-confirm      Skip confirmation prompts
#   -h, --help              Show this help
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
GITHUB_ORG=""
GITHUB_REPO=""
ENVIRONMENTS=""
STRATEGY=""
AUTH0_DOMAIN=""
AUTO_CONFIRM=false
SELECTED_APP_ID=""
CREATE_NEW_APP=true
CONFIG_DESTINATION=""
AZURE_SUBSCRIPTION_ID=""
AZURE_APP_CONFIG_NAME=""
AZURE_KEY_VAULT_NAME=""

# Common Scopes for Terraform
# These scopes allow Terraform to manage Clients, APIs, Connections, Users, Roles, etc.
TERRAFORM_SCOPES=(\
"read:clients" "create:clients" "update:clients" "delete:clients" \
"read:client_keys" "create:client_keys" "update:client_keys" "delete:client_keys" \
"read:connections" "create:connections" "update:connections" "delete:connections" \
"read:resource_servers" "create:resource_servers" "update:resource_servers" "delete:resource_servers" \
"read:users" "create:users" "update:users" "delete:users" \
"read:client_grants" "create:client_grants" "update:client_grants" "delete:client_grants" \
"read:roles" "create:roles" "update:roles" "delete:roles" \
"read:rules" "create:rules" "update:rules" "delete:rules" \
"read:hooks" "create:hooks" "update:hooks" "delete:hooks" \
"read:actions" "create:actions" "update:actions" "delete:actions" \
"read:tenant_settings" "update:tenant_settings" \
"read:logs" \
"read:organizations" "create:organizations" "update:organizations" "delete:organizations" \
)

# Helper Functions
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() { echo -e "${CYAN}▶ $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✓ $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}" >&2; }
print_error() { echo -e "${RED}✗ $1${NC}" >&2; }

get_active_auth0_domain() {
    # Try to find the active tenant domain from Auth0 CLI config or context
    local config_file="$HOME/.config/auth0/config.json"
    local default_tenant=""
    local domain=""
    
    # 1. Try to read default tenant and its domain directly from config (Fastest)
    if [[ -f "$config_file" ]] && command -v jq &> /dev/null; then
        default_tenant=$(jq -r '.default_tenant // empty' "$config_file" 2>/dev/null)
        
        if [[ -n "$default_tenant" ]]; then
            # Attempt to get domain directly from the tenants map in config
            domain=$(jq -r --arg t "$default_tenant" '.tenants[$t].domain // empty' "$config_file" 2>/dev/null)
            
            if [[ -n "$domain" ]]; then
                echo "$domain|$default_tenant"
                return
            fi
        fi
    fi
    
    # 2. List tenants via CLI (Fallback)
    # We use --no-input to prevent any interactive prompts
    local tenants_json
    tenants_json=$(auth0 tenants list --json --no-input 2>/dev/null)
    
    if [[ -n "$tenants_json" ]]; then
        local tenant_name=""
        
        if [[ -n "$default_tenant" ]]; then
            # Try to find the domain for the default tenant
            domain=$(echo "$tenants_json" | jq -r --arg tenant "$default_tenant" '.[] | select(.name == $tenant) | .domain // empty')
            if [[ -n "$domain" ]]; then
                tenant_name="$default_tenant"
            fi
        fi
        
        # Fallback: Use the first tenant if default not found
        if [[ -z "$domain" ]]; then
            domain=$(echo "$tenants_json" | jq -r '.[0].domain // empty')
            tenant_name=$(echo "$tenants_json" | jq -r '.[0].name // empty')
        fi
        
        if [[ -n "$domain" ]]; then
            echo "$domain|$tenant_name"
        fi
    fi
}

# Input Helpers
prompt() {
    local VAR_NAME=$1
    local PROMPT_TEXT=$2
    local DEFAULT_VALUE=$3
    local CURRENT_VALUE=${!VAR_NAME}
    
    # If already set via parameter, skip prompt
    if [[ -n "$CURRENT_VALUE" ]]; then
        return
    fi
    
    local INPUT
    if [[ -n "$DEFAULT_VALUE" ]]; then
        read -p "$PROMPT_TEXT [$DEFAULT_VALUE]: " INPUT
        printf -v "$VAR_NAME" "%s" "${INPUT:-$DEFAULT_VALUE}"
    else
        read -p "$PROMPT_TEXT: " INPUT
        printf -v "$VAR_NAME" "%s" "$INPUT"
    fi
}

select_from_list() {
    local VAR_NAME=$1
    local PROMPT_TEXT=$2
    local LIST_CMD=$3
    local CURRENT_VALUE=${!VAR_NAME}

    # If already set via parameter, skip prompt
    if [[ -n "$CURRENT_VALUE" ]]; then
        return
    fi

    echo "$PROMPT_TEXT"
    
    # Get items into an array
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

    # Display items
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

select_multiple_from_list() {
    local VAR_NAME=$1
    local PROMPT_TEXT=$2
    local LIST_CMD=$3
    local CURRENT_VALUE=${!VAR_NAME}

    # If already set via parameter, skip prompt
    if [[ -n "$CURRENT_VALUE" ]]; then
        return
    fi

    echo "$PROMPT_TEXT"
    
    # Get items into an array
    local ITEMS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && ITEMS+=("$line")
    done < <(eval "$LIST_CMD")

    if [[ ${#ITEMS[@]} -eq 0 ]]; then
        echo "No items found."
        read -p "Enter manual value (comma-separated): " MANUAL_VAL
        eval "$VAR_NAME=\"$MANUAL_VAL\""
        return
    fi

    # Display items
    local i=1
    for item in "${ITEMS[@]}"; do
        echo "  $i) $item"
        ((i++))
    done
    echo "  0) Manual Input"
    echo "  a) All"

    local SELECTION
    while true; do
        read -p "Select indices (comma-separated, e.g., '1,3') or 'a' for all: " SELECTION
        
        if [[ "$SELECTION" == "0" ]]; then
            read -p "Enter manual value (comma-separated): " MANUAL_VAL
            eval "$VAR_NAME=\"$MANUAL_VAL\""
            break
        elif [[ "$SELECTION" == "a" || "$SELECTION" == "A" ]]; then
             # Join all items with comma
             local ALL_ITEMS=$(IFS=,; echo "${ITEMS[*]}")
             eval "$VAR_NAME=\"$ALL_ITEMS\""
             break
        else
            # Validation logic for indices
            local SELECTED_ITEMS=()
            local VALID=true
            
            # Split by comma
            IFS=',' read -ra INDICES <<< "$SELECTION"
            for index in "${INDICES[@]}"; do
                # Trim whitespace
                index=$(echo "$index" | xargs)
                if [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= ${#ITEMS[@]} )); then
                    SELECTED_ITEMS+=("${ITEMS[$((index-1))]}")
                else
                    VALID=false
                    echo "Invalid index: $index"
                    break
                fi
            done
            
            if [[ "$VALID" == true ]]; then
                local RESULT=$(IFS=,; echo "${SELECTED_ITEMS[*]}")
                eval "$VAR_NAME=\"$RESULT\""
                break
            fi
        fi
    done
}

select_azure_resources() {
    print_header "Azure Resource Selection"
    
    # Check if az is installed
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI (az) is required for the selected option but not installed."
        exit 1
    fi
    
    # Check Azure Login
    if ! az account show &>/dev/null; then
        echo "Please login to Azure:"
        az login -o none
    fi
    
    # 1. Select Subscription
    print_step "Selecting Subscription..."
    local subs_json
    subs_json=$(az account list --all --output json)
    
    if [[ $(echo "$subs_json" | jq length) -eq 0 ]]; then
        print_error "No Azure subscriptions found."
        exit 1
    fi
    
    echo "Available Subscriptions:"
    echo "$subs_json" | jq -r 'to_entries | .[] | "  \(.key + 1)) \(.value.name) (\(.value.id)) \(.value.isDefault | if . then "(Default)" else "" end)"'
    
    local sub_count
    sub_count=$(echo "$subs_json" | jq length)
    
    local sub_selection
    while true; do
        read -p "Select Subscription [1-$sub_count]: " sub_selection
        if [[ "$sub_selection" =~ ^[0-9]+$ ]] && (( sub_selection >= 1 && sub_selection <= sub_count )); then
            local index=$((sub_selection - 1))
            AZURE_SUBSCRIPTION_ID=$(echo "$subs_json" | jq -r ".[$index].id")
            local sub_name=$(echo "$subs_json" | jq -r ".[$index].name")
            echo "Selected: $sub_name ($AZURE_SUBSCRIPTION_ID)"
            az account set --subscription "$AZURE_SUBSCRIPTION_ID"
            break
        else
            echo "Invalid selection."
        fi
    done

    # 2. Select Resource based on CONFIG_DESTINATION
    if [[ "$CONFIG_DESTINATION" == "azure-app-config" || "$CONFIG_DESTINATION" == "azure-kv-ref" ]]; then
        
        # Select App Configuration Store
        print_step "Selecting Azure App Configuration Store..."
        local ac_json
        ac_json=$(az appconfig list --subscription "$AZURE_SUBSCRIPTION_ID" --output json 2>/dev/null || echo "[]")
        local ac_count
        ac_count=$(echo "$ac_json" | jq length)
        
        if [[ "$ac_count" -eq 0 ]]; then
            echo "No App Configuration stores found."
            read -p "Enter App Configuration Store Name: " AZURE_APP_CONFIG_NAME
        else
            echo "Available App Configuration Stores:"
            echo "$ac_json" | jq -r 'to_entries | .[] | "  \(.key + 1)) \(.value.name) (\(.value.location))"'
            echo "  0) Manual Input"
            
            local ac_sel
            while true; do
                read -p "Select Store [1-$ac_count] or 0: " ac_sel
                if [[ "$ac_sel" == "0" ]]; then
                    read -p "Enter App Configuration Store Name: " AZURE_APP_CONFIG_NAME
                    break
                elif [[ "$ac_sel" =~ ^[0-9]+$ ]] && (( ac_sel >= 1 && ac_sel <= ac_count )); then
                    AZURE_APP_CONFIG_NAME=$(echo "$ac_json" | jq -r ".[$((ac_sel-1))].name")
                    break
                else
                    echo "Invalid selection."
                fi
            done
        fi
        echo "Selected App Config: $AZURE_APP_CONFIG_NAME"
    fi
    
    if [[ "$CONFIG_DESTINATION" == "azure-kv-ref" ]]; then
        # Select Key Vault
        print_step "Selecting Azure Key Vault..."
        local kv_json
        kv_json=$(az keyvault list --subscription "$AZURE_SUBSCRIPTION_ID" --output json 2>/dev/null || echo "[]")
        local kv_count
        kv_count=$(echo "$kv_json" | jq length)
        
        if [[ "$kv_count" -eq 0 ]]; then
            echo "No Key Vaults found."
            read -p "Enter Key Vault Name: " AZURE_KEY_VAULT_NAME
        else
             echo "Available Key Vaults:"
            echo "$kv_json" | jq -r 'to_entries | .[] | "  \(.key + 1)) \(.value.name) (\(.value.location))"'
            echo "  0) Manual Input"
            
            local kv_sel
            while true; do
                read -p "Select Key Vault [1-$kv_count] or 0: " kv_sel
                if [[ "$kv_sel" == "0" ]]; then
                    read -p "Enter Key Vault Name: " AZURE_KEY_VAULT_NAME
                    break
                elif [[ "$kv_sel" =~ ^[0-9]+$ ]] && (( kv_sel >= 1 && kv_sel <= kv_count )); then
                    AZURE_KEY_VAULT_NAME=$(echo "$kv_json" | jq -r ".[$((kv_sel-1))].name")
                    break
                else
                    echo "Invalid selection."
                fi
            done
        fi
        echo "Selected Key Vault: $AZURE_KEY_VAULT_NAME"
    fi
}

save_configuration() {
    local env="$1"
    local cid="$2"
    local csec="$3"
    
    print_step "Saving Configuration for Environment: $env"
    
    if [[ "$CONFIG_DESTINATION" == "github" ]]; then
        setup_github_env_internal "$env" "$cid" "$csec"
        
    elif [[ "$CONFIG_DESTINATION" == "azure-app-config" ]]; then
        print_step "Saving to Azure App Configuration ($AZURE_APP_CONFIG_NAME) [Label: $env]..."
        
        # Set Client ID
        az appconfig kv set --name "$AZURE_APP_CONFIG_NAME" --key "AUTH0_CLIENT_ID" --label "$env" --value "$cid" --yes --output none
        
        # Set Domain
        az appconfig kv set --name "$AZURE_APP_CONFIG_NAME" --key "AUTH0_DOMAIN" --label "$env" --value "$AUTH0_DOMAIN" --yes --output none
        
        # Set Secret
        az appconfig kv set --name "$AZURE_APP_CONFIG_NAME" --key "AUTH0_CLIENT_SECRET" --label "$env" --value "$csec" --yes --output none
        
        print_success "Configuration saved to App Config."
        
    elif [[ "$CONFIG_DESTINATION" == "azure-kv-ref" ]]; then
        print_step "Saving to Azure Key Vault ($AZURE_KEY_VAULT_NAME) & App Config ($AZURE_APP_CONFIG_NAME)..."
        
        # Secret Name must contain environment to be unique in the Vault
        local secret_name="AUTH0-CLIENT-SECRET-$env"
        # Sanitize secret name (Key Vault secrets can only contain alphanumeric and dashes)
        secret_name=$(echo "$secret_name" | tr -cd 'a-zA-Z0-9-')
        
        # 1. Save Secret to Key Vault
        print_step "Setting secret '$secret_name' in Key Vault..."
        az keyvault secret set --vault-name "$AZURE_KEY_VAULT_NAME" --name "$secret_name" --value "$csec" --output none
        
        # 2. Save Reference to App Config
        # NOTE: App Config keys still use the simple name because the 'label' ($env) provides the differentiation.
        
        # Set Client ID (Plain)
        az appconfig kv set --name "$AZURE_APP_CONFIG_NAME" --key "AUTH0_CLIENT_ID" --label "$env" --value "$cid" --yes --output none
        
        # Set Domain (Plain)
        az appconfig kv set --name "$AZURE_APP_CONFIG_NAME" --key "AUTH0_DOMAIN" --label "$env" --value "$AUTH0_DOMAIN" --yes --output none
        
        # Set Secret Reference
        print_step "Creating Key Vault reference in App Config..."
        local secret_id
        secret_id=$(az keyvault secret show --vault-name "$AZURE_KEY_VAULT_NAME" --name "$secret_name" --query id -o tsv)
        
        az appconfig kv set-keyvault --name "$AZURE_APP_CONFIG_NAME" --key "AUTH0_CLIENT_SECRET" --label "$env" --secret-identifier "$secret_id" --yes --output none
        
        print_success "Configuration saved to App Config with KV Reference."
    fi
}

check_deps() {
    local missing_deps=0
    # gh is now optional/conditional, removed from core list
    for cmd in auth0 jq; do
        if ! command -v $cmd &> /dev/null; then
            print_error "$cmd is required but not installed."
            missing_deps=1
        fi
    done
    
    if [ $missing_deps -eq 1 ]; then
        echo "Please install missing dependencies and try again."
        exit 1
    fi
}

check_auth0_login() {
    print_step "Auth0 Authentication"
    
    # Construct scopes string for the CLI login to ensure it can perform API calls
    local scopes_str=$(IFS=,; echo "${TERRAFORM_SCOPES[*]}")

    # Always prompt for login or tenant selection to ensure correct context
    echo "Please authenticate or select your Auth0 tenant:"
    if ! auth0 login --scopes "$scopes_str"; then
         print_error "Auth0 login failed."
         exit 1
    fi
    
    DETECTED_INFO=$(get_active_auth0_domain)
    if [[ -n "$DETECTED_INFO" ]]; then
        DETECTED_DOMAIN="${DETECTED_INFO%%|*}"
        DETECTED_TENANT="${DETECTED_INFO#*|}"
        print_success "Authenticated with Auth0 ($DETECTED_DOMAIN)"
    else
        print_success "Authenticated with Auth0."
    fi
}

show_help() {
    cat << EOF
Auth0-GitHub Connection Script

USAGE:
  Interactive:    ./connect-auth0-github.sh
  With params:    ./connect-auth0-github.sh [OPTIONS]

OPTIONS:
  -o, --github-org        GitHub organization or username
  -r, --github-repo       GitHub repository name
  -e, --environments      Comma-separated environments (e.g. dev,staging,prod)
  -s, --strategy          App strategy:
                            single  - One M2M app for all environments (Best for Free Plan)
                            per-env - Separate M2M app per environment
  -d, --auth0-domain      Auth0 Domain (e.g. mytenant.auth0.com)
  -i, --app-id            Existing Auth0 Client ID (skips creation)
  -y, --auto-confirm      Skip confirmation prompts
  -h, --help              Show this help message
EOF
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--github-org)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option $1 requires an argument."
                show_help
                exit 1
            fi
            GITHUB_ORG="$2"
            shift 2
            ;;
        -r|--github-repo)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option $1 requires an argument."
                show_help
                exit 1
            fi
            GITHUB_REPO="$2"
            shift 2
            ;;
        -e|--environments)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option $1 requires an argument."
                show_help
                exit 1
            fi
            ENVIRONMENTS="$2"
            shift 2
            ;;
        -s|--strategy)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option $1 requires an argument."
                show_help
                exit 1
            fi
            STRATEGY="$2"
            shift 2
            ;;
        -d|--auth0-domain)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option $1 requires an argument."
                show_help
                exit 1
            fi
            AUTH0_DOMAIN="$2"
            shift 2
            ;;
        -i|--app-id)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option $1 requires an argument."
                show_help
                exit 1
            fi
            SELECTED_APP_ID="$2"
            CREATE_NEW_APP=false
            shift 2
            ;;
        -y|--auto-confirm) AUTO_CONFIRM=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

check_deps
check_auth0_login

#-------------------------------------------------------------------------------
# Input Collection
#-------------------------------------------------------------------------------

# 0. Select Configuration Destination
if [[ -z "$CONFIG_DESTINATION" ]]; then
    echo "Choose Configuration Destination:"
    echo "  1) GitHub Secrets"
    echo "  2) Azure App Configuration"
    echo "  3) Azure Key Vault with reference to App Config"
    read -p "Select [1]: " dest_input
    
    case "${dest_input:-1}" in
        1) CONFIG_DESTINATION="github" ;;
        2) CONFIG_DESTINATION="azure-app-config" ;;
        3) CONFIG_DESTINATION="azure-kv-ref" ;;
        *) CONFIG_DESTINATION="github" ;;
    esac
fi

# Run Azure Resource Selection if needed
if [[ "$CONFIG_DESTINATION" != "github" ]]; then
    select_azure_resources
fi

# 1. Project Context
GH_CLI_AVAILABLE=false
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
    GH_CLI_AVAILABLE=true
fi

FETCH_FROM_GITHUB=false

if [[ "$CONFIG_DESTINATION" == "github" ]]; then
    FETCH_FROM_GITHUB=true
elif [[ "$GH_CLI_AVAILABLE" == "true" ]]; then
    # Azure destination, but we can use GitHub for context
    echo ""
    read -p "Fetch Project Name & Environments from GitHub? [Y/n] " use_gh
    if [[ "${use_gh:-Y}" =~ ^[Yy]$ ]]; then
        FETCH_FROM_GITHUB=true
    fi
fi

if [[ "$FETCH_FROM_GITHUB" == "true" ]]; then
    # --- GitHub Context Mode ---
    
    if [[ "$GH_CLI_AVAILABLE" == "true" ]]; then
        # Select Org/User
        select_from_list GITHUB_ORG "Select GitHub Organization or User:" \
            "{ gh api user -q .login; gh api user/orgs -q '.[].login'; }"
        
        # Select Repo
        select_from_list GITHUB_REPO "Select Repository from $GITHUB_ORG:" \
            "gh repo list $GITHUB_ORG --limit 30 --json name -q '.[].name'"
            
        # Select Environments
        if [[ -z "$ENVIRONMENTS" ]]; then
            select_multiple_from_list ENVIRONMENTS "Select Environments for $GITHUB_ORG/$GITHUB_REPO:" \
                "gh api \"repos/$GITHUB_ORG/$GITHUB_REPO/environments\" --jq '.environments[].name' 2>/dev/null"
        fi
    else
        # Fallback to manual input or git detection (Only if dest=github and no CLI)
        if [[ -z "$GITHUB_ORG" ]]; then
            CURRENT_ORG=$(git remote get-url origin 2>/dev/null | sed -E 's/.*[:/]([^/]+)\/[^/]+(\.git)?/\1/' || echo "")
            prompt GITHUB_ORG "GitHub Organization" "$CURRENT_ORG"
        fi
        
        if [[ -z "$GITHUB_REPO" ]]; then
            CURRENT_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's/.*\/([^/]+)(\.git)?/\1/' || echo "")
            prompt GITHUB_REPO "GitHub Repository" "$CURRENT_REPO"
        fi
    fi

    if [[ -z "$GITHUB_ORG" ]] || [[ -z "$GITHUB_REPO" ]]; then
        print_error "GitHub Organization and Repository are required."
        exit 1
    fi

    # Fallback for environments if CLI failed or didn't return anything
    if [[ -z "$ENVIRONMENTS" ]]; then
        read -p "Environments (comma-separated, e.g. dev,staging,prod) [dev,staging,prod]: " input
        ENVIRONMENTS="${input:-dev,staging,prod}"
    fi

else
    # --- Manual / Azure Mode without GitHub Context ---
    if [[ -z "$GITHUB_REPO" ]]; then
        read -p "Project Name (used for Auth0 App naming): " input
        if [[ -z "$input" ]]; then
            print_error "Project Name is required."
            exit 1
        fi
        GITHUB_REPO="$input"
    fi
    
    # Environments (Manual)
    if [[ -z "$ENVIRONMENTS" ]]; then
        read -p "Environments (comma-separated, e.g. dev,staging,prod) [dev,staging,prod]: " input
        ENVIRONMENTS="${input:-dev,staging,prod}"
    fi
fi

# 4. Strategy & App Selection
if [[ -z "$SELECTED_APP_ID" ]]; then
    if [[ "$STRATEGY" == "" ]]; then
        echo ""
        echo "Choose Setup Mode:"
        echo "  1) Create New App (Single or Per-Env)"
        echo "  2) Use Existing App (Applies to all environments)"
        read -p "Select [1]: " mode_input
        
        if [[ "${mode_input:-1}" == "2" ]]; then
            CREATE_NEW_APP=false
            STRATEGY="single"
            
            print_step "Fetching M2M Apps from Auth0..."
            
            # Fetch all apps to ensure we catch them regardless of CLI filtering quirks
            RAW_APPS_JSON=$(auth0 apps list --json 2>/dev/null)
            
            # Check if it looks like JSON
            if ! echo "$RAW_APPS_JSON" | jq empty > /dev/null 2>&1; then
                print_error "Failed to fetch apps. Ensure you are logged in."
                RAW_APPS_JSON="[]"
            fi
            
            # Filter for M2M (non_interactive)
            APPS_JSON=$(echo "$RAW_APPS_JSON" | jq '[.[] | select(.app_type == "non_interactive")]')
            APP_COUNT=$(echo "$APPS_JSON" | jq '. | length')
            
            if [[ "$APP_COUNT" == "0" ]]; then
                 TOTAL_APPS=$(echo "$RAW_APPS_JSON" | jq length)
                 if [[ "$TOTAL_APPS" -gt 0 ]]; then
                     print_warning "No apps with type 'non_interactive' (M2M) found, but $TOTAL_APPS other apps exist."
                     read -p "Show all apps instead? [y/N] " show_all
                     if [[ "$show_all" =~ ^[Yy]$ ]]; then
                         APPS_JSON="$RAW_APPS_JSON"
                         APP_COUNT="$TOTAL_APPS"
                     else
                        print_warning "No M2M apps found. Switching to creation mode."
                        CREATE_NEW_APP=true
                     fi
                 else
                     print_warning "No apps found in this tenant. Switching to creation mode."
                     CREATE_NEW_APP=true
                 fi
            fi
            
            if [[ "$CREATE_NEW_APP" != "true" ]]; then
                echo "Available Apps:"
                echo "$APPS_JSON" | jq -r 'to_entries | .[] | "  \(.key + 1)) \(.value.name) (\(.value.client_id)) [\(.value.app_type)]"'
                echo "  0) Manual Input"
                
                while true; do
                    read -p "Select App [1-$APP_COUNT] or 0: " app_selection
                    
                    if [[ "$app_selection" == "0" ]]; then
                        read -p "Enter Client ID: " SELECTED_APP_ID
                        break
                    elif [[ "$app_selection" =~ ^[0-9]+$ ]] && [ "$app_selection" -le "$APP_COUNT" ] && [ "$app_selection" -gt 0 ]; then
                        index=$((app_selection - 1))
                        SELECTED_APP_ID=$(echo "$APPS_JSON" | jq -r ".[$index].client_id")
                        APP_NAME=$(echo "$APPS_JSON" | jq -r ".[$index].name")
                        echo "Selected: $APP_NAME ($SELECTED_APP_ID)"
                        break
                    else
                        echo "Invalid selection."
                    fi
                done
            fi
        fi
    fi
fi

if [[ "$CREATE_NEW_APP" == "true" && -z "$STRATEGY" ]]; then
    echo ""
    echo "Choose Strategy:"
    echo "  1) Single M2M App (Recommended for Free Plan)"
    echo "  2) One M2M App per Environment"
    read -p "Select [1]: " input
    case "${input:-1}" in
        1) STRATEGY="single" ;;
        2) STRATEGY="per-env" ;;
        *) STRATEGY="single" ;;
    esac
fi

# 5. Auth0 Domain
if [[ -z "$AUTH0_DOMAIN" ]]; then
    # Try to find domain from the selected app if possible
    # (If we selected an app, we might not have the domain in the JSON unless we fetched full details,
    # but the 'tenants list' is the standard way).
    
    DETECTED_INFO=$(get_active_auth0_domain)
    
    if [[ -n "$DETECTED_INFO" ]]; then
        # Check if the output contains multiple lines or garbage (just in case)
        DETECTED_INFO=$(echo "$DETECTED_INFO" | head -n 1 | xargs)
        
        # Split domain and tenant name
        DETECTED_DOMAIN="${DETECTED_INFO%%|*}"
        DETECTED_TENANT="${DETECTED_INFO#*|}"
        
        if [[ -n "$DETECTED_DOMAIN" ]]; then
            echo "Detected Active Tenant: $DETECTED_TENANT"
            echo "Using Auth0 Domain:     $DETECTED_DOMAIN"
            AUTH0_DOMAIN="$DETECTED_DOMAIN"
        else
            print_error "Detected tenant info but failed to extract domain."
        fi
    else
        print_error "Could not detect Auth0 Domain from active tenant. Please ensure you are logged in 'auth0 login'."
    fi

    if [[ -z "$AUTH0_DOMAIN" ]]; then
        read -p "Auth0 Domain (e.g. mytenant.auth0.com): " input
        AUTH0_DOMAIN="$input"
    fi
fi

if [[ -z "$AUTH0_DOMAIN" ]]; then
    print_error "Auth0 Domain is required."
    exit 1
fi

# Confirmation
if [[ "$AUTO_CONFIRM" != "true" ]]; then
    print_header "Configuration Review"
    if [[ "$CONFIG_DESTINATION" == "github" ]]; then
        echo "GitHub Repo:      $GITHUB_ORG/$GITHUB_REPO"
    else
        echo "Project Name:     $GITHUB_REPO"
        echo "Destination:      $CONFIG_DESTINATION"
        if [[ -n "$AZURE_APP_CONFIG_NAME" ]]; then
             echo "App Config:       $AZURE_APP_CONFIG_NAME"
        fi
        if [[ -n "$AZURE_KEY_VAULT_NAME" ]]; then
             echo "Key Vault:        $AZURE_KEY_VAULT_NAME"
        fi
    fi
    echo "Environments:     $ENVIRONMENTS"
    if [[ -n "$SELECTED_APP_ID" ]]; then
        echo "Mode:             Existing App ($SELECTED_APP_ID)"
    else
        echo "Mode:             Create New App(s)"
        echo "Strategy:         $STRATEGY"
    fi
    echo "Auth0 Domain:     $AUTH0_DOMAIN"
    echo ""
    read -p "Proceed? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

#-------------------------------------------------------------------------------
# Main Logic
#-------------------------------------------------------------------------------

print_header "Starting Configuration"

# Check Auth0 Login
# check_auth0_login  <-- REMOVED: Redundant check. We checked at start and 'get_or_create_app' will fail if not logged in.

# Check GitHub Login (Only if GitHub destination)
if [[ "$CONFIG_DESTINATION" == "github" ]]; then
    if ! gh auth status &>/dev/null; then
        print_error "Not authenticated with GitHub. Please run 'gh auth login' first."
        exit 1
    fi
fi

# Common Scopes for Terraform
# (Defined at the top of the script)

ensure_app_scopes() {
    local client_id="$1"
    local audience="https://$AUTH0_DOMAIN/api/v2/"
    local scope_str="${TERRAFORM_SCOPES[*]}"
    
    print_step "Checking Management API Access..."

    # List grants for this client and audience
    local grants_json
    grants_json=$(auth0 api get "client-grants?audience=$audience&client_id=$client_id" || echo "[]")
    
    local grant_id
    grant_id=$(echo "$grants_json" | jq -r '.[0].id // empty')
    
    if [[ -z "$grant_id" ]]; then
        print_step "No existing grant found. Creating new grant..."
        local grant_payload
        grant_payload=$(jq -n \
            --arg client_id "$client_id" \
            --arg audience "$audience" \
            --arg scope "$scope_str" \
            '{client_id: $client_id, audience: $audience, scope: ($scope | split(" "))}')

        if ! output=$(auth0 api post client-grants --data "$grant_payload" 2>&1); then
            print_error "Failed to create client grant."
            echo "Error details: $output" >&2
            return 1
        fi
        print_success "Grant created successfully."
    else
        print_step "Found existing grant ($grant_id). Verifying scopes..."
        # Get current scopes
        local current_scopes
        current_scopes=$(echo "$grants_json" | jq -r '.[0].scope[]')
        
        # Check for missing scopes
        local missing_scopes=()
        for scope in "${TERRAFORM_SCOPES[@]}"; do
            if ! echo "$current_scopes" | grep -q "^$scope$"; then
                missing_scopes+=("$scope")
            fi
        done
        
        if [[ ${#missing_scopes[@]} -gt 0 ]]; then
            print_warning "Missing scopes: ${missing_scopes[*]}"
            print_step "Updating grant with missing scopes..."
            
            # Combine current and required, sort, unique
            local all_scopes
            all_scopes=$(echo -e "${current_scopes}\n${TERRAFORM_SCOPES[*]// /\\n}" | sort -u | tr '\n' ' ')
            
            local patch_payload
            patch_payload=$(jq -n --arg scope "$all_scopes" '{scope: ($scope | split(" ") | map(select(length > 0)))}')
            
            if ! output=$(auth0 api patch "client-grants/$grant_id" --data "$patch_payload" 2>&1); then
                 print_error "Failed to update client grant."
                 echo "Error details: $output" >&2
                 return 1
            fi
            print_success "Grant updated successfully."
        else
            print_success "All required scopes are already present."
        fi
    fi
}

get_or_create_app() {
    local app_name_or_id="$1"
    local use_existing="$2" # true/false
    
    local client_id
    local client_secret
    
    if [[ "$use_existing" == "true" ]]; then
        client_id="$app_name_or_id"
        print_step "Using existing app: $client_id"
        
        # Verify it exists and get secret
        local app_json
        if ! app_json=$(auth0 apps show "$client_id" --reveal-secrets --json 2>/dev/null); then
            print_error "App with Client ID $client_id not found."
            exit 1
        fi
        client_secret=$(echo "$app_json" | jq -r '.client_secret')
        
    else
        print_step "Creating Auth0 M2M App: $app_name_or_id"
        local app_json
        app_json=$(auth0 apps create \
            --name "$app_name_or_id" \
            --type m2m \
            --description "Created by Dilcore-Scripts for Terraform" \
            --json)
        
        client_id=$(echo "$app_json" | jq -r '.client_id')
        client_secret=$(echo "$app_json" | jq -r '.client_secret')
        
        if [[ -z "$client_id" || "$client_id" == "null" ]]; then
            print_error "Failed to create Auth0 App."
            echo "$app_json" >&2
            exit 1
        fi
        print_success "Created App with Client ID: $client_id"
    fi

    # Check/Grant Scopes (Common logic for both new and existing)
    ensure_app_scopes "$client_id"
    
    # Test Token Generation
    print_step "Verifying App Credentials..."
    local audience="https://$AUTH0_DOMAIN/api/v2/"
    
    # Use 'auth0 test token' to get an access token
    # We need to extract just the token from the output or use --json if supported (auth0 test token usually outputs raw text or json)
    # Checking help for auth0 test token... usually it prints access_token.
    # Let's try to fetch it.
    
    if auth0 test token "$client_id" --audience "$audience" >/dev/null 2>&1; then
        print_success "Successfully generated Access Token for Management API."
    else
        print_warning "Failed to run token test. You might need to authorize the app manually first or check client secret."
    fi

    echo "$client_id"
    echo "$client_secret"
}

setup_github_env_internal() {
    local env="$1"
    local cid="$2"
    local csec="$3"
    
    print_step "Configuring GitHub Environment: $env"
    
    # Create Environment (idempotent-ish)
    gh api "repos/$GITHUB_ORG/$GITHUB_REPO/environments/$env" -X PUT &>/dev/null || true
    
    # 1. Set Secrets (Sensitive Data)
    local secrets_to_set=(
        "AUTH0_CLIENT_SECRET|$csec"
    )

    for secret_pair in "${secrets_to_set[@]}"; do
        local name="${secret_pair%%|*}"
        local value="${secret_pair#*|}"
        local output

        if ! output=$(gh secret set "$name" -e "$env" -b "$value" -R "$GITHUB_ORG/$GITHUB_REPO" 2>&1); then
            print_error "Failed to set secret '$name' for environment '$env' in '$GITHUB_ORG/$GITHUB_REPO'."
            echo "Exit Code: $?"
            echo "Output: $output"
            exit 1
        fi
    done

    # 2. Set Variables (Non-Sensitive Data)
    local vars_to_set=(
        "AUTH0_DOMAIN|$AUTH0_DOMAIN"
        "AUTH0_CLIENT_ID|$cid"
    )

    for var_pair in "${vars_to_set[@]}"; do
        local name="${var_pair%%|*}"
        local value="${var_pair#*|}"
        local output

        if ! output=$(gh variable set "$name" -e "$env" -b "$value" -R "$GITHUB_ORG/$GITHUB_REPO" 2>&1); then
            print_error "Failed to set variable '$name' for environment '$env' in '$GITHUB_ORG/$GITHUB_REPO'."
            echo "Exit Code: $?"
            echo "Output: $output"
            exit 1
        fi
    done
    
    print_success "Configuration (Secrets & Variables) set for $env"
}

IFS=',' read -ra ENV_ARRAY <<< "$ENVIRONMENTS"

if [[ -n "$SELECTED_APP_ID" ]]; then
    # Mode: Existing App (Single App Logic effectively)
    
        # Use mapfile (bash 4+) or manual read for portability
        # readarray is not available on older macOS bash (3.2)
        CREDS_RAW=$(get_or_create_app "$SELECTED_APP_ID" "true")
        
        if [[ -z "$CREDS_RAW" ]]; then
            print_error "Failed to retrieve app credentials."
            exit 1
        fi

        CREDS_ARRAY=()
        while IFS= read -r line; do
            CREDS_ARRAY+=("$line")
        done <<< "$CREDS_RAW"
        
        CLIENT_ID="${CREDS_ARRAY[0]}"
        CLIENT_SECRET="${CREDS_ARRAY[1]}"
        
        for env in "${ENV_ARRAY[@]}"; do
            # Trim whitespace
            env=$(echo "$env" | xargs)
            save_configuration "$env" "$CLIENT_ID" "$CLIENT_SECRET"
        done

elif [[ "$STRATEGY" == "single" ]]; then
    # Single App Strategy
    APP_NAME="Terraform-GitHub-$GITHUB_REPO-ALL"
    
    CREDS_RAW=$(get_or_create_app "$APP_NAME" "false")
    
    if [[ -z "$CREDS_RAW" ]]; then
        print_error "Failed to retrieve app credentials."
        exit 1
    fi

    CREDS_ARRAY=()
    while IFS= read -r line; do
        CREDS_ARRAY+=("$line")
    done <<< "$CREDS_RAW"

    CLIENT_ID="${CREDS_ARRAY[0]}"
    CLIENT_SECRET="${CREDS_ARRAY[1]}"
    
    for env in "${ENV_ARRAY[@]}"; do
        # Trim whitespace
        env=$(echo "$env" | xargs)
        save_configuration "$env" "$CLIENT_ID" "$CLIENT_SECRET"
    done

else
    # Per-Env Strategy
    for env in "${ENV_ARRAY[@]}"; do
        env=$(echo "$env" | xargs)
        APP_NAME="Terraform-GitHub-$GITHUB_REPO-${env^^}"
        
        CREDS_RAW=$(get_or_create_app "$APP_NAME" "false")
        
        if [[ -z "$CREDS_RAW" ]]; then
            print_error "Failed to retrieve app credentials for $env."
            exit 1
        fi

        CREDS_ARRAY=()
        while IFS= read -r line; do
            CREDS_ARRAY+=("$line")
        done <<< "$CREDS_RAW"

        CLIENT_ID="${CREDS_ARRAY[0]}"
        CLIENT_SECRET="${CREDS_ARRAY[1]}"
        
        save_configuration "$env" "$CLIENT_ID" "$CLIENT_SECRET"
    done
fi

print_header "Configuration Complete!"
echo "You can now use these credentials in your Terraform GitHub Actions."
echo "Ensure your Terraform provider is configured to use:"
echo "  domain        = var.auth0_domain"
echo "  client_id     = var.auth0_client_id"
echo "  client_secret = var.auth0_client_secret"
echo ""

if [[ "$CONFIG_DESTINATION" == "github" ]]; then
    echo "Note: AUTH0_DOMAIN and AUTH0_CLIENT_ID are set as GitHub Variables."
    echo "      AUTH0_CLIENT_SECRET is set as a GitHub Secret."
elif [[ "$CONFIG_DESTINATION" == "azure-app-config" ]]; then
    echo "Note: Configuration saved to Azure App Configuration: $AZURE_APP_CONFIG_NAME"
    echo "      Keys are labeled with environment names (e.g., dev, prod)."
elif [[ "$CONFIG_DESTINATION" == "azure-kv-ref" ]]; then
    echo "Note: Configuration saved to Azure App Configuration ($AZURE_APP_CONFIG_NAME) and Key Vault ($AZURE_KEY_VAULT_NAME)."
    echo "      Secrets are in Key Vault, referenced by App Configuration."
fi
echo ""