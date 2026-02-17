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
  value = var.config.verbose ? "The client_ip ${var.config.client_ip} is whitelisted in the DB and VM firewalls." : null
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
# Optional debug outputs
# -------------------------
# output "provisioning_command" {
#   value = var.config.verbose ? "bash -c '...long command...'" : null
# }
# output "eros_fqdn" {
#   description = "This is the FQDN of the Eros DB server for accessing it."
#   value       = var.config.verbose ? azurerm_mssql_server.eros.fully_qualified_domain_name : null
# }
