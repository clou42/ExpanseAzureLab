# =========================
# Outputs (verbose-aware)
# =========================
# NOTE: Only the tycho_terminal_webapp_fqdn is always printed.
# All other outputs are gated by var.config.verbose and become null when verbose = false.

# Web-app landing page (CTF entry point)
output "tycho_terminal_webapp_fqdn" {
  description = "FQDN of the Azure App Service tycho-terminal"
  value       = azurerm_linux_web_app.tycho-terminal.default_hostname
}

# -------------------------
# VMs
# -------------------------
output "Rocinante_public_IP" {
  description = "This value allows connecting via SSH to the Rocinante VM using the configured SSH key. Only works if client_ip is configured."
  value       = var.config.verbose ? azurerm_public_ip.res-15.ip_address : null
}

output "Rocinante_admin_user" {
  description = "This value allows connecting via SSH to the Rocinante VM using the configured SSH key. Only works if client_ip is configured."
  value       = var.config.verbose ? azurerm_linux_virtual_machine.rocinante.admin_username : null
}

output "Scopuli_public_IP" {
  description = "This value allows connecting via SSH to the Scopuli VM using the configured SSH key. Only works if client_ip is configured."
  value       = var.config.verbose ? azurerm_public_ip.res-16.ip_address : null
}

output "Scopuli_admin_user" {
  description = "This value allows connecting via SSH to the Scopuli VM using the configured SSH key. Only works if client_ip is configured."
  value       = var.config.verbose ? azurerm_linux_virtual_machine.scopuli.admin_username : null
}

output "Donnager_public_IP" {
  description = "This value allows connecting via RDP to the Donnager Windows VM. Only works if client_ip is configured."
  value       = var.config.verbose ? azurerm_public_ip.donnager_ip.ip_address : null
}

output "Donnager_admin_user" {
  description = "Admin username for the Donnager Windows VM."
  value       = var.config.verbose ? azurerm_windows_virtual_machine.donnager.admin_username : null
}

output "Donnager_MI_principal_id" {
  description = "This ID allows utilizing the user-assigned identity on the Donnager Windows VM to access Key Vault."
  value       = var.config.verbose ? azurerm_user_assigned_identity.jovian_access.principal_id : null
}
# -------------------------
# Users
# -------------------------
output "Users" {
  value = var.config.verbose ? [
    for user in azuread_user.users :
    "${user.user_principal_name}:${nonsensitive(user.password)}"
  ] : null
}

# -------------------------
# Service Principals
# -------------------------
output "priv_sp_proto_client_id" {
  description = "This value is needed to use the privileged service principal Proto if desired."
  value       = var.config.verbose ? azuread_application.protomolecule_app.client_id : null
}

output "priv_sp_proto_client_secret" {
  description = "This value is needed to use the privileged service principal Proto if desired."
  value       = var.config.verbose ? nonsensitive(azuread_service_principal_password.protomolecule_sp_password.value) : null
}

output "tycho_db_sa_sp_client_id" {
  description = "This value is needed to use the service principal Fred Johnson (DB SA on Tycho) if desired."
  value       = var.config.verbose ? azuread_application.tycho_sa_app.client_id : null
}

output "tycho_db_sp_client_secret" {
  description = "This value is needed to use the service principal Fred Johnson (DB SA on Tycho) if desired."
  value       = var.config.verbose ? nonsensitive(azuread_service_principal_password.tycho_sa_sp_password.value) : null
}

output "tenant_id" {
  description = "This value is needed to use the service principals if desired."
  value       = var.config.verbose ? data.azurerm_client_config.current.tenant_id : null
}

# -------------------------
# Firewall info
# -------------------------
output "whitelisted_client_ip" {
  value = var.config.verbose ? "The client_ip ${var.config.client_ip} is whitelisted in the DB, VM firewalls, and tycho-terminal web app (and SCM)." : null
}

# -------------------------
# Managed Identity
# -------------------------
output "KeysToTheScopuli_MI_principal_id" {
  description = "This ID allows utilizing the user-assigned identity on the Rocinante VM to access e.g. the Scopuli VM."
  value       = var.config.verbose ? azurerm_user_assigned_identity.keystothescopuli.principal_id : null
}

# -------------------------
# SQL Infos
# -------------------------
output "tycho_fqdn" {
  description = "This is the FQDN of the Tycho DB server for accessing it."
  value       = var.config.verbose ? azurerm_mssql_server.tycho.fully_qualified_domain_name : null
}

# -------------------------
# SP creds (map)
# -------------------------
output "sp_credentials" {
  value = var.config.verbose ? {
    for key, pwd in azuread_application_password.pwd :
    key => {
      app_id   = azuread_application.app[key].client_id
      password = nonsensitive(pwd.value)
    }
  } : null
}

# -------------------------
# Storage Account Info
# -------------------------
output "storage_account_name" {
  description = "Storage account name for blob storage and file share access"
  value       = var.config.verbose ? azurerm_storage_account.storage_labpallas.name : null
}

output "blob_container_name" {
  description = "Blob container name where credentials.json and other files are stored"
  value       = var.config.verbose ? azurerm_storage_container.pallas.name : null
}

output "credentials_json_blob_url" {
  description = "Public URL to access credentials.json from blob storage"
  value       = var.config.verbose ? "https://${azurerm_storage_account.storage_labpallas.name}.blob.core.windows.net/${azurerm_storage_container.pallas.name}/credentials.json" : null
}

output "file_share_name" {
  description = "Azure File Share name where credentials.json is exposed via SMB"
  value       = var.config.verbose ? azurerm_storage_share.credentials_share.name : null
}

output "file_share_unc_path" {
  description = "UNC path to access the file share (requires storage account key or Azure AD authentication)"
  value       = var.config.verbose ? "\\\\${azurerm_storage_account.storage_labpallas.name}.file.core.windows.net\\${azurerm_storage_share.credentials_share.name}" : null
}
# -------------------------
# Optional debug outputs
# -------------------------
# output "provisioning_command" {
#   value = var.config.verbose ? "bash -c '...long command...'" : null
# }
# output "eros_fqdn" {
#   description = "This is the FQDN of the Eros DB server for accessing it."
#   value       = var.config.verbose ? azurerm_mssql_server.eros.fully_qualified_domain_name : null
# }
