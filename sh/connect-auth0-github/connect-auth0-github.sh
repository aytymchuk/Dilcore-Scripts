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

# Helper Functions
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

check_deps() {
    local missing_deps=0
    for cmd in gh auth0 jq; do
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

#-------------------------------------------------------------------------------
# Input Collection
#-------------------------------------------------------------------------------

# Detect GitHub CLI availability
GH_CLI_AVAILABLE=false
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
    GH_CLI_AVAILABLE=true
fi

# 1. GitHub Org & Repo
if [[ "$GH_CLI_AVAILABLE" == true ]]; then
    # Select Org/User
    # Note: older gh cli versions of 'org list' might not support --json, so we fallback or use text processing if needed.
    # But usually 'gh api user/orgs' is safer.
    select_from_list GITHUB_ORG "Select GitHub Organization or User:" \
        "{ gh api user -q .login; gh api user/orgs -q '.[].login'; }"
    
    # Select Repo
    select_from_list GITHUB_REPO "Select Repository from $GITHUB_ORG:" \
        "gh repo list $GITHUB_ORG --limit 30 --json name -q '.[].name'"
else
    # Fallback to manual input or git detection
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

# 3. Environments
if [[ -z "$ENVIRONMENTS" ]]; then
    if [[ "$GH_CLI_AVAILABLE" == true ]]; then
        # Try to list environments for multiple selection
        select_multiple_from_list ENVIRONMENTS "Select Environments for $GITHUB_ORG/$GITHUB_REPO:" \
            "gh api \"repos/$GITHUB_ORG/$GITHUB_REPO/environments\" --jq '.environments[].name' 2>/dev/null"
    fi
    
    # If still empty (e.g., gh failed, no envs found, or manual input chosen in select_multiple), ask manually
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
            
            echo "Fetching M2M Apps..."
            # Get list of M2M apps
            APPS_JSON=$(auth0 apps list --type m2m --json 2>/dev/null || echo "[]")
            APP_COUNT=$(echo "$APPS_JSON" | jq '. | length')
            
            if [[ "$APP_COUNT" == "0" ]]; then
                print_warning "No M2M apps found. Switching to creation mode."
                CREATE_NEW_APP=true
            else
                echo "Available M2M Apps:"
                echo "$APPS_JSON" | jq -r 'to_entries | .[] | "  \(.key + 1)) \(.value.name) (\(.value.client_id))"'
                
                read -p "Select App (Number or Client ID): " app_selection
                
                # Check if input is a number
                if [[ "$app_selection" =~ ^[0-9]+$ ]] && [ "$app_selection" -le "$APP_COUNT" ] && [ "$app_selection" -gt 0 ]; then
                    index=$((app_selection - 1))
                    SELECTED_APP_ID=$(echo "$APPS_JSON" | jq -r ".[$index].client_id")
                    APP_NAME=$(echo "$APPS_JSON" | jq -r ".[$index].name")
                    echo "Selected: $APP_NAME ($SELECTED_APP_ID)"
                else
                    SELECTED_APP_ID="$app_selection"
                fi
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
    # Try to get from auth0 cli config if possible, or just ask
    # We can try to get it from `auth0 tenants list` if logged in, but let's just ask or check current context
    DETECTED_DOMAIN=$(auth0 tenants list --json 2>/dev/null | jq -r '.[0].domain // empty' || echo "")
    
    if [[ -n "$DETECTED_DOMAIN" ]]; then
        read -p "Auth0 Domain [$DETECTED_DOMAIN]: " input
        AUTH0_DOMAIN="${input:-$DETECTED_DOMAIN}"
    else
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
    echo "GitHub Repo:      $GITHUB_ORG/$GITHUB_REPO"
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
if ! auth0 tenants list &>/dev/null; then
    print_error "Not authenticated with Auth0. Please run 'auth0 login' first."
    exit 1
fi

# Check GitHub Login
if ! gh auth status &>/dev/null; then
    print_error "Not authenticated with GitHub. Please run 'gh auth login' first."
    exit 1
fi

# Common Scopes for Terraform
# These scopes allow Terraform to manage Clients, APIs, Connections, Users, Roles, etc.
TERRAFORM_SCOPES=(\
"read:clients" "create:clients" "update:clients" "delete:clients" \
"read:client_keys" "create:client_keys" "update:client_keys" "delete:client_keys" \
"read:connections" "create:connections" "update:connections" "delete:connections" \
"read:resource_servers" "create:resource_servers" "update:resource_servers" "delete:resource_servers" \
"read:users" "create:users" "update:users" "delete:users" \
"read:roles" "create:roles" "update:roles" "delete:roles" \
"read:rules" "create:rules" "update:rules" "delete:rules" \
"read:hooks" "create:hooks" "update:hooks" "delete:hooks" \
"read:actions" "create:actions" "update:actions" "delete:actions" \
"read:tenant_settings" "update:tenant_settings" \
"read:logs" \
"read:organizations" "create:organizations" "update:organizations" "delete:organizations" \
)

ensure_app_scopes() {
    local client_id="$1"
    local audience="https://$AUTH0_DOMAIN/api/v2/"
    local scope_str="${TERRAFORM_SCOPES[*]}"
    
    print_step "Checking Management API Access..."

    # List grants for this client and audience
    local grants_json
    grants_json=$(auth0 api get "client-grants?audience=$audience&client_id=$client_id" --json || echo "[]")
    
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

        if ! auth0 api post client-grants --data "$grant_payload" &>/dev/null; then
            print_error "Failed to create client grant."
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
            
            if ! auth0 api patch "client-grants/$grant_id" --data "$patch_payload" &>/dev/null; then
                 print_error "Failed to update client grant."
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
            echo "$app_json"
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
    
    local token_response
    if token_response=$(auth0 test token "$client_id" --audience "$audience" --json 2>/dev/null); then
        local access_token
        access_token=$(echo "$token_response" | jq -r '.access_token')
        
        if [[ -n "$access_token" && "$access_token" != "null" ]]; then
             print_success "Successfully generated Access Token for Management API."
        else
             print_warning "Could not verify credentials automatically. Please check manually."
             echo "Response: $token_response"
        fi
    else
        print_warning "Failed to run token test. You might need to authorize the app manually first or check client secret."
    fi

    echo "$client_id"
    echo "$client_secret"
}

setup_github_env() {
    local env="$1"
    local cid="$2"
    local csec="$3"
    
    print_step "Configuring GitHub Environment: $env"
    
    # Create Environment (idempotent-ish)
    gh api "repos/$GITHUB_ORG/$GITHUB_REPO/environments/$env" -X PUT &>/dev/null || true
    
    # Set Secrets
    local secrets_to_set=(
        "AUTH0_DOMAIN|$AUTH0_DOMAIN"
        "AUTH0_CLIENT_ID|$cid"
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
    
    print_success "Secrets set for $env"
}

IFS=',' read -ra ENV_ARRAY <<< "$ENVIRONMENTS"

if [[ -n "$SELECTED_APP_ID" ]]; then
    # Mode: Existing App (Single App Logic effectively)
    
    readarray -t CREDS_ARRAY < <(get_or_create_app "$SELECTED_APP_ID" "true")
    CLIENT_ID="${CREDS_ARRAY[0]}"
    CLIENT_SECRET="${CREDS_ARRAY[1]}"
    
    for env in "${ENV_ARRAY[@]}"; do
        # Trim whitespace
        env=$(echo "$env" | xargs)
        setup_github_env "$env" "$CLIENT_ID" "$CLIENT_SECRET"
    done

elif [[ "$STRATEGY" == "single" ]]; then
    # Single App Strategy
    APP_NAME="Terraform-GitHub-$GITHUB_REPO-ALL"
    
    readarray -t CREDS_ARRAY < <(get_or_create_app "$APP_NAME" "false")
    CLIENT_ID="${CREDS_ARRAY[0]}"
    CLIENT_SECRET="${CREDS_ARRAY[1]}"
    
    for env in "${ENV_ARRAY[@]}"; do
        # Trim whitespace
        env=$(echo "$env" | xargs)
        setup_github_env "$env" "$CLIENT_ID" "$CLIENT_SECRET"
    done

else
    # Per-Env Strategy
    for env in "${ENV_ARRAY[@]}"; do
        env=$(echo "$env" | xargs)
        APP_NAME="Terraform-GitHub-$GITHUB_REPO-${env^^}"
        
        readarray -t CREDS_ARRAY < <(get_or_create_app "$APP_NAME" "false")
        CLIENT_ID="${CREDS_ARRAY[0]}"
        CLIENT_SECRET="${CREDS_ARRAY[1]}"
        
        setup_github_env "$env" "$CLIENT_ID" "$CLIENT_SECRET"
    done
fi

print_header "Configuration Complete!"
echo "You can now use these credentials in your Terraform GitHub Actions."
echo "Ensure your Terraform provider is configured to use:"
echo "  domain        = var.auth0_domain"
echo "  client_id     = var.auth0_client_id"
echo "  client_secret = var.auth0_client_secret"
echo ""