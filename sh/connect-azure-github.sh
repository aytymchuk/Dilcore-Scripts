#!/bin/bash

#===============================================================================
# Azure-GitHub OIDC Connection Script
#
# Supports both interactive mode and CLI parameters for automation.
#
# INTERACTIVE:
#   ./connect-azure-github.sh
#
# WITH PARAMETERS:
#   ./connect-azure-github.sh \
#     --subscription "My Subscription" \
#     --github-org "myorg" \
#     --github-repo "myrepo" \
#     --environments "dev,staging,production" \
#     --naming-strategy "suffixed" \
#     --auto-confirm
#
# ALL OPTIONS:
#   -s, --subscription      Azure subscription ID or name
#   -o, --github-org        GitHub organization or username
#   -r, --github-repo       GitHub repository name
#   -a, --app-name          App Registration name (auto-generated if not set)
#   -e, --environments      Comma-separated environments (default: production)
#   -n, --naming-strategy   Secret naming: suffixed|environment|simple
#   -t, --github-token      GitHub PAT (optional, uses gh CLI if not set)
#   -m, --method            Auth method: cli|api|manual (default: auto-detect)
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

#-------------------------------------------------------------------------------
# Default Values
#-------------------------------------------------------------------------------

SUBSCRIPTION=""
GITHUB_ORG=""
GITHUB_REPO=""
APP_NAME=""
ENVIRONMENTS=""
NAMING_STRATEGY=""
GITHUB_TOKEN=""
AUTH_METHOD=""
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

show_help() {
    cat << EOF
Azure-GitHub OIDC Connection Script

USAGE:
  Interactive:    ./connect-azure-github.sh
  With params:    ./connect-azure-github.sh [OPTIONS]

OPTIONS:
  -s, --subscription      Azure subscription ID or name
  -o, --github-org        GitHub organization or username
  -r, --github-repo       GitHub repository name
  -a, --app-name          App Registration name (auto-generated if omitted)
  -e, --environments      Comma-separated environments (default: production)
  -n, --naming-strategy   Secret naming strategy:
                            suffixed    - AZURE_CLIENT_ID_SUBNAME (default)
                            environment - Secrets per GitHub environment
                            simple      - AZURE_CLIENT_ID (single sub only)
  -t, --github-token      GitHub PAT for API auth (uses gh CLI if omitted)
  -m, --method            GitHub auth method: cli | api | manual
  -y, --auto-confirm      Skip all confirmation prompts
  -h, --help              Show this help message

EXAMPLES:
  # Fully interactive
  ./connect-azure-github.sh

  # Non-interactive with all parameters
  ./connect-azure-github.sh \\
    --subscription "Production" \\
    --github-org "mycompany" \\
    --github-repo "infrastructure" \\
    --environments "dev,staging,prod" \\
    --naming-strategy "suffixed" \\
    --method "cli" \\
    --auto-confirm

  # Partial parameters (will prompt for missing)
  ./connect-azure-github.sh -o myorg -r myrepo

  # Using GitHub API with token
  ./connect-azure-github.sh \\
    -s "Dev Subscription" \\
    -o myorg -r myrepo \\
    -t "ghp_xxxxxxxxxxxx" \\
    -y

EOF
    exit 0
}

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

prompt_secret() {
    local VAR_NAME=$1
    local PROMPT_TEXT=$2
    local CURRENT_VALUE=${!VAR_NAME}
    
    if [[ -n "$CURRENT_VALUE" ]]; then
        return
    fi
    
    read -sp "$PROMPT_TEXT: " INPUT
    echo ""
    eval "$VAR_NAME=\"$INPUT\""
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
# Parse Command Line Arguments
#-------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--subscription)
            SUBSCRIPTION="$2"
            shift 2
            ;;
        -o|--github-org)
            GITHUB_ORG="$2"
            shift 2
            ;;
        -r|--github-repo)
            GITHUB_REPO="$2"
            shift 2
            ;;
        -a|--app-name)
            APP_NAME="$2"
            shift 2
            ;;
        -e|--environments)
            ENVIRONMENTS="$2"
            shift 2
            ;;
        -n|--naming-strategy)
            NAMING_STRATEGY="$2"
            shift 2
            ;;
        -t|--github-token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        -m|--method)
            AUTH_METHOD="$2"
            shift 2
            ;;
        -y|--auto-confirm)
            AUTO_CONFIRM=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

#-------------------------------------------------------------------------------
# Prerequisites Check
#-------------------------------------------------------------------------------

print_header "Azure-GitHub OIDC Connection Setup"

if ! command -v az &> /dev/null; then
    print_error "Azure CLI not installed"
    exit 1
fi

if ! az account show &> /dev/null; then
    print_error "Not logged in to Azure. Run 'az login' first."
    exit 1
fi

print_success "Azure CLI ready"

# Detect GitHub CLI
GH_CLI_AVAILABLE=false
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
    GH_CLI_AVAILABLE=true
    print_success "GitHub CLI available"
fi

#-------------------------------------------------------------------------------
# Subscription Selection
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

SUB_SUFFIX=$(echo "$SUBSCRIPTION_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//' | sed 's/_$//' | tr '[:lower:]' '[:upper:]')

echo -e "Selected: ${GREEN}$SUBSCRIPTION_NAME${NC}"
echo -e "Suffix: ${CYAN}$SUB_SUFFIX${NC}"

#-------------------------------------------------------------------------------
# GitHub Configuration
#-------------------------------------------------------------------------------

print_header "GitHub Configuration"

if [[ "$GH_CLI_AVAILABLE" == true ]]; then
    # Select Org/User
    select_from_list GITHUB_ORG "Select GitHub Organization or User:" \
        "{ gh api user -q .login; gh org list --json login -q '.[].login'; }"
    
    # Select Repo
    select_from_list GITHUB_REPO "Select Repository from $GITHUB_ORG:" \
        "gh repo list $GITHUB_ORG --limit 30 --json name -q '.[].name'"
else
    prompt GITHUB_ORG "GitHub organization or username" ""
    prompt GITHUB_REPO "GitHub repository name" ""
fi

GITHUB_REPO_FULL="$GITHUB_ORG/$GITHUB_REPO"

# Default app name
if [[ -z "$APP_NAME" ]]; then
    DEFAULT_APP="GitHub-$GITHUB_REPO-$SUB_SUFFIX"
    prompt APP_NAME "App Registration name" "$DEFAULT_APP"
fi

if [[ "$GH_CLI_AVAILABLE" == true ]]; then
    # List environments to help user choose - Single Selection
    echo "Fetching environments for $GITHUB_REPO_FULL..."
    
    # Use single select from list instead of multiple
    select_from_list ENVIRONMENTS "Select ONE environment for $GITHUB_REPO_FULL:" \
        "gh api \"repos/$GITHUB_REPO_FULL/environments\" --jq '.environments[].name' 2>/dev/null"
    
    if [[ -z "$ENVIRONMENTS" ]]; then
         prompt ENVIRONMENTS "Environment name" "production"
    fi
else
    prompt ENVIRONMENTS "Environment name" "production"
fi
# Treat as single item array for compatibility
ENV_ARRAY=("$ENVIRONMENTS")

#-------------------------------------------------------------------------------
# GitHub Auth Method
#-------------------------------------------------------------------------------

print_header "GitHub Authentication"

if [[ -z "$AUTH_METHOD" ]]; then
    echo "Select GitHub authentication method:"
    echo "  1) cli     - GitHub CLI (gh)"
    echo "  2) api     - GitHub API with PAT"
    echo "  3) manual  - Skip, show secrets only"
    echo ""
    
    if [[ "$GH_CLI_AVAILABLE" == true ]]; then
        DEFAULT_METHOD="1"
    else
        DEFAULT_METHOD="3"
    fi
    
    read -p "Select [${DEFAULT_METHOD}]: " METHOD_CHOICE
    METHOD_CHOICE=${METHOD_CHOICE:-$DEFAULT_METHOD}
    
    case $METHOD_CHOICE in
        1) AUTH_METHOD="cli" ;;
        2) AUTH_METHOD="api" ;;
        3) AUTH_METHOD="manual" ;;
        *) AUTH_METHOD="cli" ;;
    esac
fi

# Get token if using API
if [[ "$AUTH_METHOD" == "api" && -z "$GITHUB_TOKEN" ]]; then
    echo ""
    echo "Create PAT at: https://github.com/settings/tokens"
    echo "Required scope: repo"
    prompt_secret GITHUB_TOKEN "GitHub Personal Access Token"
    
    # Validate
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/user")
    
    if [[ "$HTTP_CODE" != "200" ]]; then
        print_error "Invalid token"
        exit 1
    fi
    print_success "Token validated"
fi

#-------------------------------------------------------------------------------
# Naming Strategy
#-------------------------------------------------------------------------------

# Force naming strategy to environment since we are doing 1:1 mapping
NAMING_STRATEGY="environment"

#-------------------------------------------------------------------------------
# Confirmation
#-------------------------------------------------------------------------------

print_header "Configuration Summary"

echo "Azure:"
echo "  Subscription: $SUBSCRIPTION_NAME"
echo "  Subscription ID: $SUBSCRIPTION_ID"
echo "  Tenant ID: $TENANT_ID"
echo ""
echo "GitHub:"
echo "  Repository: $GITHUB_REPO_FULL"
echo "  Auth Method: $AUTH_METHOD"
echo "  Environments: ${ENV_ARRAY[*]}"
echo "  Naming: $NAMING_STRATEGY"
echo ""
echo "App Registration: $APP_NAME"
echo ""

if ! confirm "Proceed with setup?"; then
    print_warning "Cancelled"
    exit 0
fi

#-------------------------------------------------------------------------------
# Create Azure Resources
#-------------------------------------------------------------------------------

print_header "Creating Azure Resources"

# App Registration
EXISTING_APP=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING_APP" ]]; then
    print_warning "App exists: $EXISTING_APP"
    if confirm "Use existing app?"; then
        APP_ID=$EXISTING_APP
    else
        exit 1
    fi
else
    print_step "Creating App Registration..."
    APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
    print_success "Created: $APP_ID"
fi

# Service Principal
EXISTING_SP=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv 2>/dev/null || echo "")

if [[ -z "$EXISTING_SP" ]]; then
    print_step "Creating Service Principal..."
    az ad sp create --id "$APP_ID" --output none
    print_success "Created Service Principal"
    print_step "Waiting for propagation (20s)..."
    sleep 20
else
    print_warning "Service Principal exists"
fi

# Role Assignment
print_step "Assigning Contributor role..."
EXISTING_ROLE=$(az role assignment list --assignee "$APP_ID" --role "Contributor" \
    --scope "/subscriptions/$SUBSCRIPTION_ID" --query "[0].id" -o tsv 2>/dev/null || echo "")

if [[ -z "$EXISTING_ROLE" ]]; then
    az role assignment create --assignee "$APP_ID" --role "Contributor" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" --output none
    print_success "Role assigned"
else
    print_warning "Role already assigned"
fi

#-------------------------------------------------------------------------------
# Federated Credentials
#-------------------------------------------------------------------------------

print_header "Creating Federated Credentials"

create_credential() {
    local NAME=$1
    local SUBJECT=$2
    
    EXISTING=$(az ad app federated-credential list --id "$APP_ID" \
        --query "[?name=='$NAME'].id" -o tsv 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING" ]]; then
        print_warning "Exists: $NAME"
        return
    fi
    
    print_step "Creating: $NAME"
    az ad app federated-credential create --id "$APP_ID" --parameters "{
        \"name\": \"$NAME\",
        \"issuer\": \"https://token.actions.githubusercontent.com\",
        \"subject\": \"$SUBJECT\",
        \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none
    print_success "Created: $NAME"
}

create_credential "main-branch" "repo:$GITHUB_REPO_FULL:ref:refs/heads/main"
create_credential "pull-requests" "repo:$GITHUB_REPO_FULL:pull_request"

for ENV in "${ENV_ARRAY[@]}"; do
    ENV=$(echo "$ENV" | xargs)
    create_credential "env-$ENV" "repo:$GITHUB_REPO_FULL:environment:$ENV"
done

#-------------------------------------------------------------------------------
# Push Secrets to GitHub
#-------------------------------------------------------------------------------

push_secret_cli() {
    local NAME=$1
    local VALUE=$2
    local ENV=$3
    
    if [[ -n "$ENV" ]]; then
        # Ensure environment exists (create if not)
        gh api "repos/$GITHUB_REPO_FULL/environments/$ENV" -X PUT -f wait_timer=0 2>/dev/null || true
        # The -f flag sends strings; wait_timer needs to be an integer if sent as JSON.
        # But `gh api` with `-f` sends fields as strings. For integer fields we should use `-F` (for fields) but wait_timer is special.
        # Actually, let's just create the environment without specifying wait_timer if it fails, or rely on `gh secret set` creating it?
        # `gh secret set --env` requires the environment to exist?
        # Let's try to create it properly.
        # For `gh api`, use `-f` for string and `-F` for other types or construct JSON manually.
        # However, sending `{ "wait_timer": 0 }` via input stream is safer.
        echo '{"wait_timer":0}' | gh api "repos/$GITHUB_REPO_FULL/environments/$ENV" -X PUT --input - >/dev/null 2>&1 || true
        
        echo "$VALUE" | gh secret set "$NAME" --repo "$GITHUB_REPO_FULL" --env "$ENV" 2>/dev/null
    else
        echo "$VALUE" | gh secret set "$NAME" --repo "$GITHUB_REPO_FULL" 2>/dev/null
    fi
}

push_secret_api() {
    local NAME=$1
    local VALUE=$2
    local ENV=$3
    
    local KEY_URL="https://api.github.com/repos/$GITHUB_REPO_FULL/actions/secrets/public-key"
    local SECRET_URL="https://api.github.com/repos/$GITHUB_REPO_FULL/actions/secrets/$NAME"
    
    if [[ -n "$ENV" ]]; then
        # Create environment if needed - Ensure wait_timer is integer 0
        curl -s -X PUT \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$GITHUB_REPO_FULL/environments/$ENV" \
            -d '{"wait_timer":0}' > /dev/null
        
        KEY_URL="https://api.github.com/repos/$GITHUB_REPO_FULL/environments/$ENV/secrets/public-key"
        SECRET_URL="https://api.github.com/repos/$GITHUB_REPO_FULL/environments/$ENV/secrets/$NAME"
    fi
    
    # Get public key
    KEY_RESPONSE=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$KEY_URL")
    PUBLIC_KEY=$(echo "$KEY_RESPONSE" | jq -r '.key')
    KEY_ID=$(echo "$KEY_RESPONSE" | jq -r '.key_id')
    
    # Encrypt (requires python3 + pynacl)
    ENCRYPTED=$(python3 -c "
import base64
from nacl import encoding, public
pk = public.PublicKey(base64.b64decode('$PUBLIC_KEY'))
sealed = public.SealedBox(pk).encrypt('$VALUE'.encode())
print(base64.b64encode(sealed).decode())
" 2>/dev/null)
    
    # Push secret
    curl -s -X PUT \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$SECRET_URL" \
        -d "{\"encrypted_value\":\"$ENCRYPTED\",\"key_id\":\"$KEY_ID\"}" > /dev/null
}

if [[ "$AUTH_METHOD" != "manual" ]]; then
    print_header "Pushing Secrets to GitHub"
    
    push_secret() {
        local NAME=$1
        local VALUE=$2
        local ENV=$3
        
        if [[ "$AUTH_METHOD" == "cli" ]]; then
            push_secret_cli "$NAME" "$VALUE" "$ENV" && \
                print_success "Set: $NAME ${ENV:+(env: $ENV)}" || \
                print_error "Failed: $NAME"
        else
            push_secret_api "$NAME" "$VALUE" "$ENV" && \
                print_success "Set: $NAME ${ENV:+(env: $ENV)}" || \
                print_error "Failed: $NAME"
        fi
    }
    
    case $NAMING_STRATEGY in
        suffixed)
            push_secret "AZURE_CLIENT_ID_$SUB_SUFFIX" "$APP_ID"
            push_secret "AZURE_TENANT_ID" "$TENANT_ID"
            push_secret "AZURE_SUBSCRIPTION_ID_$SUB_SUFFIX" "$SUBSCRIPTION_ID"
            ;;
        environment)
            for ENV in "${ENV_ARRAY[@]}"; do
                ENV=$(echo "$ENV" | xargs)
                push_secret "AZURE_CLIENT_ID" "$APP_ID" "$ENV"
                push_secret "AZURE_TENANT_ID" "$TENANT_ID" "$ENV"
                push_secret "AZURE_SUBSCRIPTION_ID" "$SUBSCRIPTION_ID" "$ENV"
            done
            ;;
        simple)
            push_secret "AZURE_CLIENT_ID" "$APP_ID"
            push_secret "AZURE_TENANT_ID" "$TENANT_ID"
            push_secret "AZURE_SUBSCRIPTION_ID" "$SUBSCRIPTION_ID"
            ;;
    esac
fi

#-------------------------------------------------------------------------------
# Output
#-------------------------------------------------------------------------------

OUTPUT_DIR="./github-azure-connections"
mkdir -p "$OUTPUT_DIR"

cat > "$OUTPUT_DIR/${SUB_SUFFIX}.json" << EOF
{
  "subscription": {
    "id": "$SUBSCRIPTION_ID",
    "name": "$SUBSCRIPTION_NAME",
    "tenantId": "$TENANT_ID"
  },
  "appRegistration": {
    "name": "$APP_NAME",
    "clientId": "$APP_ID"
  },
  "github": {
    "repository": "$GITHUB_REPO_FULL",
    "environments": $(printf '%s\n' "${ENV_ARRAY[@]}" | jq -R . | jq -s .),
    "namingStrategy": "$NAMING_STRATEGY"
  },
  "secrets": {
    "clientIdSecret": "AZURE_CLIENT_ID${NAMING_STRATEGY:+_$SUB_SUFFIX}",
    "tenantIdSecret": "AZURE_TENANT_ID",
    "subscriptionIdSecret": "AZURE_SUBSCRIPTION_ID${NAMING_STRATEGY:+_$SUB_SUFFIX}"
  },
  "values": {
    "clientId": "$APP_ID",
    "tenantId": "$TENANT_ID",
    "subscriptionId": "$SUBSCRIPTION_ID"
  },
  "createdAt": "$(date -Iseconds)"
}
EOF

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------

print_header "Setup Complete!"

echo -e "${GREEN}Connection established: $SUBSCRIPTION_NAME ↔ $GITHUB_REPO_FULL${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$AUTH_METHOD" == "manual" ]]; then
    echo -e "${YELLOW}Add these secrets to GitHub manually:${NC}"
    echo ""
    case $NAMING_STRATEGY in
        suffixed)
            echo "  AZURE_CLIENT_ID_$SUB_SUFFIX = $APP_ID"
            echo "  AZURE_TENANT_ID = $TENANT_ID"
            echo "  AZURE_SUBSCRIPTION_ID_$SUB_SUFFIX = $SUBSCRIPTION_ID"
            ;;
        environment)
            echo "  Per environment (${ENV_ARRAY[*]}):"
            echo "    AZURE_CLIENT_ID = $APP_ID"
            echo "    AZURE_TENANT_ID = $TENANT_ID"
            echo "    AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
            ;;
        simple)
            echo "  AZURE_CLIENT_ID = $APP_ID"
            echo "  AZURE_TENANT_ID = $TENANT_ID"
            echo "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
            ;;
    esac
else
    echo -e "${GREEN}Secrets pushed to GitHub automatically!${NC}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Config saved: ${CYAN}$OUTPUT_DIR/${SUB_SUFFIX}.json${NC}"
echo ""
echo "Run again for additional subscriptions."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
