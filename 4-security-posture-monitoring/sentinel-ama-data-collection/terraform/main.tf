terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "vm_size" {
  type    = string
  default = "Standard_B2as_v2"
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-ama"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-ama"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "sentinel" {
  workspace_id = azurerm_log_analytics_workspace.law.id
}

# Private VM: no public IP and no inbound rules. Logs leave through the agent, outbound only.
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-ama"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.40.0.0/16"]
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.40.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm-ama"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-vm-ama-linux"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Key exists only so the VM can be created with password login disabled. Nobody logs in;
# the test runs through Run Command.
resource "tls_private_key" "vm" {
  algorithm = "ED25519"
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "vm-ama-linux"
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.vm.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # AMA authenticates to the DCR and workspace with the VM's managed identity.
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_virtual_machine_extension" "ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}

resource "azurerm_monitor_data_collection_rule" "syslog" {
  name                = "dcr-syslog-linux"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  kind                = "Linux"

  destinations {
    log_analytics {
      name                  = "law-ama"
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["law-ama"]
  }

  data_sources {
    # Authentication logs are the security signal, so collect every level.
    syslog {
      name           = "auth-all-levels"
      facility_names = ["auth", "authpriv"]
      log_levels     = ["Debug", "Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
      streams        = ["Microsoft-Syslog"]
    }

    # General system noise only from Warning up, which keeps ingestion cost down.
    syslog {
      name           = "system-warning-up"
      facility_names = ["syslog", "user", "daemon"]
      log_levels     = ["Warning", "Error", "Critical", "Alert", "Emergency"]
      streams        = ["Microsoft-Syslog"]
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.sentinel]
}

resource "azurerm_monitor_data_collection_rule_association" "vm" {
  name                    = "dcra-vm-ama-linux"
  target_resource_id      = azurerm_linux_virtual_machine.vm.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.syslog.id
}

resource "azurerm_sentinel_alert_rule_scheduled" "ssh_bruteforce" {
  name                       = "ssh-bruteforce-syslog"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.sentinel.workspace_id
  display_name               = "Lab: SSH brute force against a Linux VM"
  description                = "Five or more failed SSH logins from one source address against one host within the lookback window, from Syslog collected by the Azure Monitor Agent."
  severity                   = "Medium"
  tactics                    = ["CredentialAccess"]
  techniques                 = ["T1110"]

  query = <<-KQL
    Syslog
    | where Facility in ("auth", "authpriv")
    | where SyslogMessage has "Failed password"
    | extend SourceIP = extract(@"from (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", 1, SyslogMessage)
    | extend TargetUser = extract(@"for (invalid user )?(\S+) from", 2, SyslogMessage)
    | summarize Attempts = count(), Users = make_set(TargetUser), FirstSeen = min(TimeGenerated), LastSeen = max(TimeGenerated) by Computer, SourceIP
    | where Attempts >= 5
  KQL

  query_frequency      = "PT5M"
  query_period         = "PT15M"
  trigger_operator     = "GreaterThan"
  trigger_threshold    = 0
  suppression_enabled  = true
  suppression_duration = "PT1H"

  event_grouping {
    aggregation_method = "AlertPerResult"
  }

  entity_mapping {
    entity_type = "Host"
    field_mapping {
      identifier  = "HostName"
      column_name = "Computer"
    }
  }

  entity_mapping {
    entity_type = "IP"
    field_mapping {
      identifier  = "Address"
      column_name = "SourceIP"
    }
  }

  incident {
    create_incident_enabled = true
    grouping {
      enabled = false
    }
  }
}

output "workspace" {
  value = azurerm_log_analytics_workspace.law.name
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}

output "dcr" {
  value = azurerm_monitor_data_collection_rule.syslog.name
}
