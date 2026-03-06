# Auth0-GitHub Connection Script

This script automates the process of connecting Auth0 to GitHub repository environments for Terraform deployments. It creates Machine-to-Machine (M2M) applications in Auth0 and populates the necessary credentials as GitHub Secrets.

## Features

- **Automated M2M App Creation**: Creates Auth0 M2M applications configured for Terraform.
- **Existing App Integration**: Can select and reuse existing M2M applications.
- **Flexible Strategies**:
  - **Single App**: One M2M app shared across all environments (Ideal for Auth0 Free Plan with limited app quota).
  - **Per-Environment**: Separate M2M apps for Dev, Staging, Prod, etc. (Better isolation).
- **Interactive Selection**:
  - Automatically fetches and lists GitHub Organizations, Repositories, and Environments using `gh` CLI.
  - Supports multi-selection for environments (including "All" option).
- **GitHub Integration**: Automatically creates GitHub Environments and sets secrets (`AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`).
- **Azure Integration**: Optionally save credentials to Azure App Configuration or Azure Key Vault (with App Config reference) instead of GitHub Secrets.
- **Permissions**: Automatically checks and grants necessary Management API scopes for Terraform operations.
- **Verification**: Automatically tests generated credentials using `auth0 test token` to ensure validity.

## Prerequisites

Ensure you have the following CLI tools installed and authenticated:

1.  **GitHub CLI (`gh`)**:
    ```bash
    brew install gh
    gh auth login
    ```
2.  **Auth0 CLI (`auth0`)**:
    ```bash
    brew tap auth0/auth0-cli
    brew install auth0
    auth0 login
    ```
3.  **jq**: JSON processor
    ```bash
    brew install jq
    ```
4.  **Azure CLI (`az`)** (Optional, for Azure integration):
    ```bash
    brew install azure-cli
    az login
    ```

## Usage

### Interactive Mode

Simply run the script and follow the prompts:

```bash
./connect-auth0-github.sh
```

### Non-Interactive (Automation)

You can pass arguments to skip prompts:

```bash
# Create new app(s)
./connect-auth0-github.sh \
  --github-org "my-org" \
  --github-repo "my-repo" \
  --environments "dev,staging,prod" \
  --strategy "single" \
  --auth0-domain "mytenant.auth0.com" \
  --auto-confirm

# Reuse an existing app (by ID)
./connect-auth0-github.sh \
  --github-org "my-org" \
  --github-repo "my-repo" \
  --environments "dev,staging,prod" \
  --app-id "client_id_of_existing_app" \
  --auth0-domain "mytenant.auth0.com" \
  --auto-confirm
```

## Generated Secrets

The script will create the following secrets in your GitHub Repository Environments:

- `AUTH0_DOMAIN`: Your Auth0 tenant domain.
- `AUTH0_CLIENT_ID`: The Client ID of the created M2M App.
- `AUTH0_CLIENT_SECRET`: The Client Secret of the created M2M App.

## Terraform Configuration

Once the secrets are set, you can configure your Terraform Auth0 Provider like this:

```hcl
variable "auth0_domain" {}
variable "auth0_client_id" {}
variable "auth0_client_secret" {}

provider "auth0" {
  domain        = var.auth0_domain
  client_id     = var.auth0_client_id
  client_secret = var.auth0_client_secret
}
```
