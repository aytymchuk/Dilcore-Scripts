# Dilcore Scripts

![CodeRabbit Reviews](https://img.shields.io/coderabbit/prs/github/aytymchuk/Dilcore-Scripts?utm_source=oss&utm_medium=github&utm_campaign=aytymchuk%2FDilcore-Scripts&labelColor=171717&color=FF570A&link=https%3A%2F%2Fcoderabbit.ai&label=CodeRabbit+Reviews)

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

### 3. Azure App Configuration & GitHub Secrets Setup

A script to manage Azure App Configuration access for GitHub Actions and Terraform. It grants necessary roles (Subscription Owner, Data Owner) to Service Principals and configures secrets for App Configuration consumption.

*   **Location**: [`sh/setup-azure-app-config-github/setup-azure-app-config-github.sh`](sh/setup-azure-app-config-github/setup-azure-app-config-github.sh)
*   **Documentation**: [Read detailed instructions](sh/setup-azure-app-config-github/README.md)

---

## Quick Start

1.  **Step 1: Connect Azure to GitHub**
    This sets up the App Registration, Service Principal, OIDC Federation, and basic secrets.
    ```bash
    ./sh/connect-azure-github/connect-azure-github.sh
    ```

2.  **Step 2: Setup Terraform Backend**
    This creates the Storage Account and configures backend-specific secrets.
    ```bash
    ./sh/setup-azure-terraform-backend-github/setup-azure-terraform-backend-github.sh
    ```

3.  **Step 3: Setup App Configuration**
    This configures App Configuration resources and grants access.
    ```bash
    ./sh/setup-azure-app-config-github/setup-azure-app-config-github.sh
    ```
