###############################################################################
# SQL Trigger Escalation module
#
# Demonstrates SQL Server / Azure SQL DML triggers executing in the security
# context of the user that CAUSES the trigger to fire (not the user that
# created it)
#
# The vulnerable table dbo.fleet_heartbeat is created by blob_resources/
# expanse_init.sql (which is provisioned by the existing Scopuli SQL
# provisioning extension). This file only:
#   1. layers the "misconfig" grants/denies onto the webapp MI after it has
#      been created by that same extension, and
#   2. installs a recurring writer on the Donnager VM.
###############################################################################

###############################################################################
# 1. Grants on the webapp MI (the "low-priv attacker").
#
# Runs on Scopuli (which already has db_owner on tycho-db via its MI), after
# scopuli_sql_provision has finished creating the [tycho-terminal-...] user.
###############################################################################

locals {
  trigger_escalation_grants_sql = <<-SQL
    GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.fleet_heartbeat TO [${azurerm_linux_web_app.tycho-terminal.name}];
    GRANT ALTER                          ON OBJECT::dbo.fleet_heartbeat TO [${azurerm_linux_web_app.tycho-terminal.name}];
  SQL

  trigger_escalation_grants_sql_b64 = base64encode(local.trigger_escalation_grants_sql)
}

resource "azurerm_virtual_machine_run_command" "scopuli_trigger_escalation_grants" {
  name               = "scopuli_trigger_escalation_grants"
  location           = azurerm_resource_group.res-114.location
  virtual_machine_id = azurerm_linux_virtual_machine.scopuli.id

  source {
    script = <<-EOT
      set -euo pipefail
      echo "${local.trigger_escalation_grants_sql_b64}" | base64 -d > /tmp/trigger_escalation_grants.sql
      curl -sS -H "Metadata:true" "http://169.254.169.254/metadata/identity/oauth2/token?resource=https://database.windows.net/&api-version=2018-02-01" \
        | jq -r .access_token > /tmp/access.tkn
      sqlcmd -S tcp:${azurerm_mssql_server.tycho.fully_qualified_domain_name} \
             -d ${azurerm_mssql_database.tycho-db.name} \
             --authentication-method ActiveDirectoryManagedIdentity \
             -I -i /tmp/trigger_escalation_grants.sql -P /tmp/access.tkn
      rm -f /tmp/trigger_escalation_grants.sql /tmp/access.tkn
    EOT
  }

  depends_on = [
    azurerm_virtual_machine_extension.scopuli_sql_provision,
    azurerm_linux_web_app.tycho-terminal,
  ]
}

###############################################################################
# 2. Periodic privileged writer on the Donnager VM.
#
# Installs C:\ExpanseLab\donnager-heartbeat-writer.ps1 and registers a Windows
# Scheduled Task that runs it as SYSTEM every
# var.config.heartbeat_interval_minutes minutes. The writer authenticates to
# tycho-db using the SQL admin creds that donnager_secrets_provision already
# wrote to HKLM:\SOFTWARE\Expanse.
#
# The writer is auto-pause aware: tycho-db is GP_S_Gen5_1 Serverless with
# auto_pause_delay_in_minutes=60. It addresses two concerns:
#   - Never wake a paused DB: queries the DB's pause state via the ARM
#     control plane (which does NOT wake the DB) and skips the write when
#     not Online. Requires Reader on the database for Donnager's MI.
#   - Never pin an Online DB awake: tracks per-session state on disk and
#     only fires heartbeats for the first 30 min of each Paused->Online
#     transition. After the window expires, writes stop so the existing
#     auto-pause clock can run down to 0 from whatever the player's last
#     activity was.
###############################################################################

resource "azurerm_role_assignment" "donnager_tycho_db_reader" {
  scope                = azurerm_mssql_database.tycho-db.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.jovian_access.principal_id

  depends_on = [
    azurerm_mssql_database.tycho-db,
    azurerm_user_assigned_identity.jovian_access,
  ]
}

locals {
  donnager_heartbeat_writer_ps1 = file("${path.module}/donnager_scripts/donnager-heartbeat-writer.ps1.tpl")

  donnager_install_heartbeat_ps1 = templatefile(
    "${path.module}/donnager_scripts/install-trigger-escalation.ps1.tpl",
    {
      writer_b64       = base64encode(local.donnager_heartbeat_writer_ps1)
      interval_minutes = var.config.heartbeat_interval_minutes
    }
  )
}

resource "azurerm_virtual_machine_run_command" "donnager_install_heartbeat_task" {
  name               = "donnager_install_heartbeat_task"
  location           = azurerm_resource_group.res-114.location
  virtual_machine_id = azurerm_windows_virtual_machine.donnager.id

  source {
    script = local.donnager_install_heartbeat_ps1
  }

  depends_on = [
    azurerm_virtual_machine_extension.donnager_secrets_provision,
    azurerm_virtual_machine_run_command.scopuli_trigger_escalation_grants,
    azurerm_role_assignment.donnager_tycho_db_reader,
  ]
}

# Outputs 

output "trigger_escalation_vuln_table" {
  description = "Name of the vulnerable table on tycho-db that the webapp MI has ALTER on. Used by the trigger-escalation CTF module."
  value       = var.config.verbose ? "dbo.fleet_heartbeat" : null
}

output "trigger_escalation_writer_interval_minutes" {
  description = "How often the Donnager VM writes a heartbeat row (and therefore fires any trigger planted on dbo.fleet_heartbeat)."
  value       = var.config.verbose ? var.config.heartbeat_interval_minutes : null
}
