# Secure AKS lab: infrastructure as code
# Builds a hardened AKS cluster, a private ACR it pulls from with its kubelet identity,
# and turns on Defender for Containers. The security proofs run afterwards with az and kubectl.
#
# Run from Azure Cloud Shell (Terraform and Azure CLI auth are already there):
#   $env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
#   terraform init
#   terraform plan -out tfplan
#   terraform apply tfplan

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "azurerm" {
  features {}
  # Providers were registered by hand in Step 2, so Terraform does not try to register them.
  resource_provider_registrations = "none"
}

# ---------- Inputs ----------

variable "location" {
  type    = string
  default = "centralindia"
}

variable "resource_group_name" {
  type    = string
  default = "lab-az-aks"
}

variable "cluster_name" {
  type    = string
  default = "aks-secure"
}

variable "acr_name" {
  description = "Globally unique, lowercase letters and numbers only."
  type        = string
  default     = "acraks7284"
}

variable "node_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "grant_cluster_admin" {
  description = "Starts false so the lab can prove the Reader role cannot write. Flip to true to elevate."
  type        = bool
  default     = false
}

# ---------- Lookups ----------

# Who is running Terraform: used for the tenant ID and for the AKS data plane role assignments.
data "azurerm_client_config" "current" {}

# Public IP of the machine running Terraform (Cloud Shell). Only this IP may reach the API server.
data "http" "my_ip" {
  url = "https://api.ipify.org"
}

locals {
  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

# ---------- Resources ----------

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
}

# Private registry. The shared admin account is never enabled.
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Standard"
  admin_enabled       = false
}

# Workspace that Defender for Containers reports into.
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-aks-secure"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  dns_prefix          = var.cluster_name
  sku_tier            = "Free"

  # Identity: Entra ID sign in, Azure RBAC for authorization, no local admin certificate.
  local_account_disabled = true

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  # Workload identity plumbing, ready for pods that need Key Vault later.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Gatekeeper admission control, so Defender recommendations can be enforced.
  azure_policy_enabled = true

  # Keep the control plane and node images patched.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  default_node_pool {
    name       = "system"
    node_count = 2
    vm_size    = var.node_vm_size
  }

  # Cluster (control plane) identity. The kubelet identity is created alongside it.
  identity {
    type = "SystemAssigned"
  }

  # Azure CNI Overlay powered by Cilium: eBPF data plane with built in network policy enforcement.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "192.168.0.0/16"
  }

  # API server stays public but only answers the Cloud Shell IP.
  api_server_access_profile {
    authorized_ip_ranges = [local.my_ip_cidr]
  }

  # Defender sensor on the nodes, reporting to the workspace above.
  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  }
}

# Kubelet identity may pull from the registry. No imagePullSecret anywhere.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# Data plane access for the person running the lab: read only to start with.
resource "azurerm_role_assignment" "me_rbac_reader" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Elevation, only when grant_cluster_admin = true.
resource "azurerm_role_assignment" "me_rbac_cluster_admin" {
  count                = var.grant_cluster_admin ? 1 : 0
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Defender for Containers plan, subscription wide.
# The plan tier alone leaves every component off, so each one is enabled explicitly.
resource "azurerm_security_center_subscription_pricing" "containers" {
  tier          = "Standard"
  resource_type = "Containers"

  extension {
    name = "ContainerRegistriesVulnerabilityAssessments"
  }

  extension {
    name = "AgentlessDiscoveryForKubernetes"
  }

  extension {
    name = "ContainerSensor"
  }
}

# ---------- Outputs ----------

output "cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "authorized_ip_range" {
  value = local.my_ip_cidr
}

output "kubelet_identity_object_id" {
  value = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}
