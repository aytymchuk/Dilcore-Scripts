# Dilcore Scripts

A collection of utility scripts for automating DevOps and Infrastructure tasks.

## Scripts

### Azure-GitHub OIDC Connection Setup

A script to automate the secure connection between Azure and GitHub Actions using OpenID Connect (OIDC). It handles the creation of Azure App Registrations, Service Principals, and automatically configures GitHub environment secrets.

*   **Location**: [`sh/connect-azure-github.sh`](sh/connect-azure-github.sh)
*   **Documentation**: [Read detailed instructions](sh/README.md)

---

## Quick Start

1.  Navigate to the `sh` directory:
    ```bash
    cd sh
    ```

2.  Run the setup script:
    ```bash
    ./connect-azure-github.sh
    ```
