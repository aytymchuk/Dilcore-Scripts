# Dilcore Scripts

A collection of utility scripts for automating DevOps and Infrastructure tasks.

## Scripts

### 1. Azure-GitHub OIDC Connection Setup

A script to automate the secure connection between Azure and GitHub Actions using OpenID Connect (OIDC). It handles the creation of Azure App Registrations, Service Principals, and automatically configures GitHub environment secrets.

*   **Location**: [`sh/connect-azure-github/connect-azure-github.sh`](sh/connect-azure-github/connect-azure-github.sh)
*   **Documentation**: [Read detailed instructions](sh/connect-azure-github/README.md)

### 2. Azure Terraform Backend & GitHub Secrets Setup

A script to bootstrap the Azure infrastructure (Storage Account) required for Terraform state management and configure the corresponding GitHub Secrets for your environments.

*   **Location**: [`sh/setup-azure-terraform-backend-github/setup-azure-terraform-backend-github.sh`](sh/setup-azure-terraform-backend-github/setup-azure-terraform-backend-github.sh)
*   **Documentation**: [Read detailed instructions](sh/setup-azure-terraform-backend-github/README.md)

---

## Quick Start

1.  Navigate to the script's directory:
    ```bash
    cd sh/connect-azure-github
    ```

2.  Run the script:
    ```bash
    ./connect-azure-github.sh
    ```
