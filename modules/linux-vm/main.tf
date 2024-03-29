locals {
  nsg_inbound_rules = { for idx, security_rule in var.nsg_inbound_rules : security_rule.name => {
    idx : idx,
    security_rule : security_rule,
    }
  }

  vm_data_disks = { for idx, data_disk in var.data_disks : data_disk.name => {
    idx : idx,
    data_disk : data_disk,
    }
  }
}

data "azurerm_resource_group" "vm" {
  name = var.resource_group_name
}

resource "random_id" "vm-sa" {
  keepers = {
    name = var.name
  }
  byte_length = 6
}


resource "azurerm_public_ip" "vm" {
  count               = var.enable_public_ip ? 1 : 0
  name                = "${var.name}-pip-${count.index}"
  resource_group_name = data.azurerm_resource_group.vm.name
  location            = coalesce(var.location, data.azurerm_resource_group.vm.location)
  allocation_method   = var.allocation_method
  sku                 = var.public_ip_sku
  domain_name_label   = var.public_ip_dns
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  #checkov:skip=CKV_AZURE_119:Ensure that Network Interfaces don't use public IPs
  name                          = "${var.name}-nic"
  resource_group_name           = data.azurerm_resource_group.vm.name
  location                      = coalesce(var.location, data.azurerm_resource_group.vm.location)
  enable_accelerated_networking = var.enable_accelerated_networking
  enable_ip_forwarding          = var.enable_ip_forwarding
  internal_dns_name_label       = var.internal_dns_name_label

  ip_configuration {
    name                          = "${var.name}-ip"
    primary                       = true
    subnet_id                     = var.vnet_subnet_id
    private_ip_address_allocation = var.private_ip_address_allocation_type
    private_ip_address            = var.private_ip_address_allocation_type == "Static" ? var.private_ip_address : null
    public_ip_address_id          = var.enable_public_ip == false ? null : join("", azurerm_public_ip.vm.*.id)
  }
}

resource "azurerm_network_security_group" "vm" {
  count               = var.existing_network_security_group_id == null ? 1 : 0
  name                = "${var.name}-nsg"
  resource_group_name = data.azurerm_resource_group.vm.name
  location            = coalesce(var.location, data.azurerm_resource_group.vm.location)

  tags = var.tags
}

resource "azurerm_network_security_rule" "nsg_rule" {
  for_each                    = { for k, v in local.nsg_inbound_rules : k => v if k != null }
  name                        = each.key
  priority                    = 100 * (each.value.idx + 1)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = each.value.security_rule.destination_port_range
  source_address_prefix       = each.value.security_rule.source_address_prefix
  destination_address_prefix  = each.value.security_rule.destination_address_prefix
  description                 = "Inbound_Port_${each.value.security_rule.destination_port_range}"
  resource_group_name         = data.azurerm_resource_group.vm.name
  network_security_group_name = azurerm_network_security_group.vm.0.name
  depends_on                  = [azurerm_network_security_group.vm]
}


resource "azurerm_network_interface_security_group_association" "nsgassoc" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = var.existing_network_security_group_id == null ? azurerm_network_security_group.vm.0.id : var.existing_network_security_group_id
}


resource "azurerm_storage_account" "vm-sa" {
  #checkov:skip=CKV_AZURE_35:Ensure default network access rule for Storage Accounts is set to deny
  #checkov:skip=CKV_AZURE_43:Ensure Storage Accounts adhere to the naming rules
  #checkov:skip=CKV_AZURE_59:Ensure that Storage accounts disallow public access
  #checkov:skip=CKV2_AZURE_1:Ensure storage for critical data are encrypted with Customer Managed Key
  #checkov:skip=CKV2_AZURE_18:Ensure that Storage Accounts use customer-managed key for encryption
  count                     = var.boot_diagnostics ? 1 : 0
  name                      = lower("bootdiag${random_id.vm-sa.hex}")
  resource_group_name       = data.azurerm_resource_group.vm.name
  location                  = coalesce(var.location, data.azurerm_resource_group.vm.location)
  account_tier              = element(split("_", var.boot_diagnostics_sa_type), 0)
  account_replication_type  = element(split("_", var.boot_diagnostics_sa_type), 1)
  min_tls_version           = var.min_tls_version
  enable_https_traffic_only = var.enable_https_traffic_only
  tags                      = var.tags

  network_rules {
    default_action = "Allow"
  }

  queue_properties {
    logging {
      delete                = true
      read                  = true
      write                 = true
      version               = "1.0"
      retention_policy_days = 10
    }

    hour_metrics {
      enabled               = true
      include_apis          = true
      version               = "1.0"
      retention_policy_days = 10
    }
    minute_metrics {
      enabled               = true
      include_apis          = true
      version               = "1.0"
      retention_policy_days = 10
    }

  }
}



resource "azurerm_linux_virtual_machine" "vm" {
  #checkov:skip=CKV_AZURE_149:Ensure that Virtual machine does not enable password authentication
  #checkov:skip=CKV_AZURE_50:Ensure Virtual Machine Extensions are not Installed
  name                            = var.name
  computer_name                   = var.name # TO DO, add some intelligence around this
  resource_group_name             = data.azurerm_resource_group.vm.name
  location                        = coalesce(var.location, data.azurerm_resource_group.vm.location)
  size                            = var.virtual_machine_size
  license_type                    = var.license_type
  admin_username                  = var.admin_username
  admin_password                  = var.disable_password_authentication == false ? var.admin_password : null
  disable_password_authentication = var.disable_password_authentication
  allow_extension_operations      = var.allow_extension_operations
  availability_set_id             = var.availability_set_id
  custom_data                     = var.custom_data
  dedicated_host_id               = var.dedicated_host_id
  encryption_at_host_enabled      = var.encryption_at_host_enabled
  eviction_policy                 = var.eviction_policy
  extensions_time_budget          = var.extensions_time_budget
  max_bid_price                   = var.max_bid_price
  priority                        = var.priority
  provision_vm_agent              = var.provision_vm_agent
  proximity_placement_group_id    = var.proximity_placement_group_id
  zone                            = var.vm_availability_zone
  user_data                       = var.user_data
  tags                            = var.tags


  network_interface_ids = [
    azurerm_network_interface.vm.id,
  ]

  additional_capabilities {
    ultra_ssd_enabled = var.ultra_ssd_enabled
  }

  dynamic "admin_ssh_key" {
    for_each = var.disable_password_authentication ? [1] : []
    content {
      username   = var.admin_username
      public_key = var.admin_ssh_key
    }
  }

  os_disk {
    name                      = "${var.name}-osdisk"
    disk_size_gb              = var.os_disk_size_gb
    storage_account_type      = var.os_disk_storage_account_type
    caching                   = var.os_disk_caching
    disk_encryption_set_id    = var.os_disk_encryption_set_id
    write_accelerator_enabled = var.os_disk_write_accelerator_enabled
  }

  dynamic "identity" {
    for_each = var.managed_identity_type != null ? [1] : []
    content {
      type         = var.managed_identity_type
      identity_ids = var.managed_identity_type == "UserAssigned" || var.managed_identity_type == "SystemAssigned, UserAssigned" ? var.managed_identity_ids : null
    }
  }


  source_image_reference {
    publisher = var.source_image_publisher
    offer     = var.source_image_offer
    sku       = var.source_image_sku
    version   = var.source_image_version
  }

  boot_diagnostics {
    storage_account_uri = var.boot_diagnostics ? join(",", azurerm_storage_account.vm-sa.*.primary_blob_endpoint) : ""
  }

  dynamic "secret" {
    for_each = var.secret
    content {
      key_vault_id = lookup(secret.value, "key_vault_id", null)
      certificate {
        url = lookup(secret.value, "url", null)
      }
    }
  }

  lifecycle {
    ignore_changes = [admin_password]
  }

  depends_on = [azurerm_network_interface_security_group_association.nsgassoc]

}


resource "azurerm_managed_disk" "data_disk" {
  #checkov:skip=CKV_AZURE_93:Ensure that managed disks use a specific set of disk encryption sets for the customer-managed key encryption
  for_each             = local.vm_data_disks
  name                 = "${var.name}_DataDisk_${each.value.idx}"
  resource_group_name  = data.azurerm_resource_group.vm.name
  location             = data.azurerm_resource_group.vm.location
  storage_account_type = lookup(each.value.data_disk, "storage_account_type", "StandardSSD_LRS")
  create_option        = "Empty"
  disk_size_gb         = each.value.data_disk.disk_size_gb
  tags                 = var.tags

}

resource "azurerm_virtual_machine_data_disk_attachment" "data_disk" {
  for_each           = local.vm_data_disks
  managed_disk_id    = azurerm_managed_disk.data_disk[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.vm.id
  lun                = each.value.data_disk.lun
  caching            = each.value.data_disk.caching

  depends_on = [
    azurerm_linux_virtual_machine.vm
  ]
}

data "template_file" "linux_provision_vm" {
  count    = var.enable_provision_script ? 1 : 0
  template = file(var.linux_provision_script)
  vars = {
    password = var.admin_password
  }
}

resource "local_sensitive_file" "linux_provision_vm" {
  count    = var.enable_provision_script ? 1 : 0
  content  = <<EOF
    ${data.template_file.linux_provision_vm[0].rendered}
  EOF
  filename = "./linux_provision_vm.sh"
}

resource "azurerm_virtual_machine_extension" "provision_linux_vm" {
  count                = var.enable_provision_script ? 1 : 0
  name                 = "provision-linux-ext"
  virtual_machine_id   = azurerm_linux_virtual_machine.vm.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = <<SETTINGS
     {
         "skipDos2Unix":false
     }
 SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
        "script": "${base64encode(local_sensitive_file.linux_provision_vm[0].content)}"
    }
 PROTECTED_SETTINGS

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.data_disk,
    azurerm_linux_virtual_machine.vm,
    local_sensitive_file.linux_provision_vm
  ]
}
