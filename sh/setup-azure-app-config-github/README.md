# Azure App Configuration & GitHub Secrets Setup

This script automates the setup of Azure App Configuration for use with GitHub Actions and Terraform. It handles resource creation (or selection), role assignments for Service Principals, and GitHub Secret configuration.

## Features

- **Interactive Selection**:
    - **Azure Subscription**: Choose from available subscriptions.
    - **Service Principal**: Select the App Registration that needs access.
    - **App Configuration**: Select an existing store or create a new one (with Resource Group selection).
    - **GitHub Repository**: Select Organization, Repository, and Environment.
- **Access Management**:
    - Grants **Owner** role to the Service Principal on the **Subscription** level (enabling it to manage resources).
    - Grants **App Configuration Data Owner** on the specific App Configuration resource (enabling data plane access for keys/values).
- **GitHub Secrets Configuration**:
    - Automatically creates/updates the GitHub Environment.
    - Sets the following secrets:
        - `AZURE_APP_CONFIG_RESOURCE_ID`: The full resource ID (for Terraform/ARM).
        - `AZURE_APP_CONFIG_NAME`: The name of the App Configuration store.
        - `AZURE_APP_CONFIG_ENDPOINT`: The endpoint URL (e.g., `https://my-app-config.azconfig.io`).
        - `AZURE_APP_CONFIG_RESOURCE_GROUP`: The resource group name.

## Prerequisites

- **Azure CLI** (`az`) installed and logged in (`az login`).
- **GitHub CLI** (`gh`) installed and logged in (`gh auth login`).
- Permissions to create Azure resources and assign roles (usually requires Owner/User Access Administrator on the subscription).
- Admin permissions on the GitHub repository to manage Environments and Secrets.

## Usage

### Interactive Mode

Run the script and follow the prompts:

```bash
./setup-azure-app-config-github.sh
```

1.  **Select Azure Subscription**.
2.  **Select App Registration**: Choose the Service Principal (e.g., the one created by `connect-azure-github.sh`).
3.  **Grant Access**: Confirm granting 'Owner' on the subscription and 'App Configuration Data Owner' on the resource.
4.  **Select App Configuration**: Choose existing or create new.
5.  **Select GitHub Repository & Environment**.
6.  **Confirm**: The script will apply changes and push secrets.

## Terraform Configuration

After running the script, you can use the configured secrets in your Terraform code.

**Variable Definition:**

```hcl
variable "app_config_resource_id" {
  type        = string
  description = "The Resource ID of the Azure App Configuration"
}
```

**Resource Usage (e.g., creating a key):**

```hcl
resource "azurerm_app_configuration_key" "example" {
  configuration_store_id = var.app_config_resource_id
  key                    = "app-setting-key"
  value                  = "some-value"
}
```

**GitHub Actions Workflow:**

Pass the secret as an input variable:

```yaml
- name: Terraform Apply
  env:
    TF_VAR_app_config_resource_id: ${{ secrets.AZURE_APP_CONFIG_RESOURCE_ID }}
  run: terraform apply -auto-approve
```
