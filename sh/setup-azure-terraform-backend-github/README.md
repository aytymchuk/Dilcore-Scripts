# Azure Terraform Backend & GitHub Secrets Setup

This script automates the creation of an Azure Storage Account for Terraform state and configures the necessary secrets in a GitHub Environment. It ensures security best practices and simplifies the bootstrapping of Terraform projects.

## Features

- **Interactive Selection**:
    - **Azure Subscription**: Choose from available subscriptions.
    - **GitHub Repository**: Select Organization, Repository, and Environment.
    - **Resource Group**: Select an existing one or create a new one.
    - **Storage Account**: Select an existing one (in the chosen RG) or create a new one.
    - **App Registration**: Select the App Registration (Service Principal) to grant access to.
- **Security Best Practices**:
    - Creates Storage Account with `Standard_LRS`, `HTTPS Only`, `TLS 1.2+`.
    - Disables public blob access.
    - Enables Blob Versioning and Soft Delete (7 days retention).
    - Uses Azure RBAC (`Storage Blob Data Contributor`) instead of Access Keys.
- **GitHub Secrets Configuration**:
    - Automatically creates/updates the GitHub Environment.
    - Sets the following secrets:
        - `TF_BACKEND_RESOURCE_GROUP`
        - `TF_BACKEND_STORAGE_ACCOUNT`
        - `TF_BACKEND_CONTAINER`
        - `TF_BACKEND_KEY`
        - `AZURE_SUBSCRIPTION_ID`
        - `AZURE_TENANT_ID`
        - `AZURE_CLIENT_ID`

## Prerequisites

- **Azure CLI** (`az`) installed and logged in (`az login`).
- **GitHub CLI** (`gh`) installed and logged in (`gh auth login`).
- Permissions to create Azure resources (Resource Groups, Storage Accounts, Role Assignments).
- Admin permissions on the GitHub repository to manage Environments and Secrets.

## Usage

### Interactive Mode

Run the script and follow the prompts:

```bash
./setup-azure-terraform-backend-github.sh
```

1.  **Select Azure Subscription**.
2.  **Select GitHub Repository & Environment**.
3.  **Select App Registration**: Choose the Service Principal that Terraform will use (usually the one created by `connect-azure-github.sh`).
4.  **Select Resource Group**: Choose an existing one (e.g., `rg-terraform-state`) or create new.
5.  **Select Storage Account**: Choose an existing one or create new.
6.  **Confirm**: The script will create resources and push secrets.

### Generated Output

The script generates a local configuration file in `./terraform-backend-config/` (e.g., `production-backend.tf`) which you can use for reference or copy to your Terraform project.

## Terraform Configuration

After running the script, your Terraform `backend` configuration in your project should look like this (using the injected secrets):

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state" # Managed via TF_BACKEND_RESOURCE_GROUP
    storage_account_name = "stterraform123"     # Managed via TF_BACKEND_STORAGE_ACCOUNT
    container_name       = "tfstate"            # Managed via TF_BACKEND_CONTAINER
    key                  = "terraform.tfstate"  # Managed via TF_BACKEND_KEY
    use_oidc             = true
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}
```

In your GitHub Actions workflow, mapping these secrets allows `terraform init` to work seamlessly.
