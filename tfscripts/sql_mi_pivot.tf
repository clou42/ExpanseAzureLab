# SQL MI Storage Pivot module
#
# Once the player has db_owner on tycho-db (via the sql_trigger_escalation
# chain), they can call sp_invoke_external_rest_endpoint and have tycho-db
# present the server's managed identity to Azure Storage.
#
# Tycho's server identity is a user-assigned MI (tycho_directory_reader),
# attached for AAD lookups. In this stage that same MI is also granted
# Storage Blob Data Reader on a separate, private storage account (archives_ceres)
# that hosts what looks like a backup / bulk-export pipeline. Buried in that
# container is a "runner" config JSON containing the next-chain
# service-principal credentials.
#
# The blob is unreachable anonymously (private container,
# allow_nested_items_to_be_public=false, default_to_oauth_authentication=true).
# Account keys exist but only the Terraform operator holds them; from the
# player's perspective the only reachable path is (a) be db_owner and
# (b) CREATE DATABASE SCOPED CREDENTIAL with IDENTITY = 'Managed Identity',
# so tycho-db assumes its MI on the outbound REST call.


# 1. Private storage account ("Ceres") - separate from the public-blob Pallas
#    account so the realistic misconfig (a backups bucket that's correctly
#    locked down at the data plane but over-permissioned at the IAM plane)
#    is not muddied by Pallas' public-blob settings.

resource "azurerm_storage_account" "archives_ceres" {
  name                = "ceres${random_string.storage_suffix.result}"
  resource_group_name = azurerm_resource_group.res-114.name
  location            = azurerm_resource_group.res-114.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Public network access stays on (Azure SQL is not a Storage "trusted
  # service") - data-plane access is gated by AAD + RBAC on a private
  # container. Anonymous blob access is denied; the player has no SAS or
  # account key, so the only reachable path is sp_invoke + the MI.
  # shared_access_key_enabled is left at its default (true) so the
  # azurerm provider can upload the blobs below using the account key;
  # the lab user holds Contributor on the RG and Pallas already relies
  # on the same model for its SAS-driven workflows.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  min_tls_version                 = "TLS1_2"

  cross_tenant_replication_enabled = false

  blob_properties {
    versioning_enabled = false
    delete_retention_policy {
      days = 7
    }
  }

  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

resource "azurerm_storage_container" "db_backups" {
  name                  = "db-backups"
  storage_account_id    = azurerm_storage_account.archives_ceres.id
  container_access_type = "private"
}

###############################################################################
# 2. RBAC: grant tycho_directory_reader (the SQL server's UMI) read on Ceres.
#
# The misconfig modeled here: a UMI created for AAD lookups was opportunistically
# reused to give the database "backup pipeline access" without spinning up a
# dedicated identity. Now any code running as db_owner on tycho-db can borrow
# that MI to read the bucket.
###############################################################################
resource "azurerm_role_assignment" "tycho_mi_ceres_blob_reader" {
  scope                = azurerm_storage_account.archives_ceres.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.tycho_directory_reader.principal_id

  depends_on = [
    azurerm_storage_account.archives_ceres,
    azurerm_user_assigned_identity.tycho_directory_reader,
    time_sleep.tycho_directory_reader_propagation,
  ]
}

# RBAC propagation buffer - the role assignment isn't usable until AAD has
# replicated it to the storage data plane. Without this, sp_invoke calls
# right after deploy will 403.
resource "time_sleep" "tycho_mi_ceres_rbac_propagation" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.tycho_mi_ceres_blob_reader]
}

###############################################################################
# 3. Blob payloads.
#
# Decoys are kept small and shaped like real artifacts a DBA might dump into
# a backups bucket. The loot ("automation/tycho-db_export_runner.json") is
# styled as an internal automation config so its name doesn't broadcast "flag
# in here" - the player has to enumerate the container, notice the auth.*
# block, and recognize it as service-principal credentials.
###############################################################################
locals {
  decoy_bacpac_meta = jsonencode({
    source_database      = "tycho-db"
    source_server        = "tycho-${random_integer.ri.result}.database.windows.net"
    bacpac_blob          = "tycho-db_2025-05-19_full.bacpac"
    bacpac_size_bytes    = 1583742976
    bacpac_sha256        = "f2a3d4c7e1b8a6f9d2e5c8b1a4f7e0d3c6b9a2e5f8d1c4b7a0e3f6c9b2e5a8d1"
    exported_at_utc      = "2025-05-19T02:14:33Z"
    exported_by          = "tycho-db-nightly-exporter"
    retention_days       = 35
    encryption_algorithm = "AES256"
  })

  decoy_crew_csv = <<-CSV
    id,first_name,last_name,faction,role,ship,status
    1,James,Holden,OPA,Captain,Rocinante,Active
    2,Naomi,Nagata,OPA,Engineer,Rocinante,Active
    3,Amos,Burton,OPA,Mechanic,Rocinante,Active
    4,Alex,Kamal,OPA,Pilot,Rocinante,Deceased
    5,Chrisjen,Avasarala,UN,Secretary-General,,Active
    6,Josephus,Miller,Star Helix,Detective,,Presumed Dead
    7,Bobbie,Draper,MCRN,Marine,,Active
  CSV

  decoy_ships_csv = <<-CSV
    id,name,registry,faction,tonnage,class,status
    1,Rocinante,OPA-ROC,OPA,2400,Frigate,Active
    2,Donnager,MCR-DON,MCRN,120000,Battleship,Destroyed
    3,Scirocco,MCR-SCI,MCRN,65000,Heavy Cruiser,Active
    4,Behemoth,OPA-BEH,OPA,450000,Battleship,Active
    5,Agatha King,UNN-AGA,UNN,75000,Destroyer,Destroyed
  CSV

  # Place exporter credentials
  loot_runner_json = jsonencode({
    exporter = {
      name          = "tycho-db-nightly-exporter"
      purpose       = "Nightly bacpac and bulk-csv export of tycho-db to db-backups container"
      owner         = "platform-data-eng@tycho.fake"
      schedule_cron = "0 2 * * *"
      version       = "1.4.2"
    }
    azure = {
      tenant_id       = data.azurerm_client_config.current.tenant_id
      subscription_id = var.config.subscription_id
      resource_group  = azurerm_resource_group.res-114.name
      storage_account = "ceres${random_string.storage_suffix.result}"
      container       = "db-backups"
    }
    auth = {
      type          = "service_principal"
      client_id     = azuread_application.exporter_sp_app.client_id
      client_secret = azuread_service_principal_password.exporter_sp_password.value
      comment       = "Used by the exporter to write bacpac archives. Reads its storage connection string from the Ganymede vault. Rotate quarterly."
    }
    telemetry = {
      logs_blob_prefix = "telemetry/exporter/"
      retain_days      = 30
    }
  })
}

resource "azurerm_storage_blob" "decoy_bacpac_meta" {
  name                   = "tycho-db_2025-05-19_full.bacpac.meta.json"
  storage_account_name   = azurerm_storage_account.archives_ceres.name
  storage_container_name = azurerm_storage_container.db_backups.name
  type                   = "Block"
  content_type           = "application/json"
  source_content         = local.decoy_bacpac_meta
}

resource "azurerm_storage_blob" "decoy_crew_csv" {
  name                   = "bulk-exports/crew_manifest_2025-05-19.csv"
  storage_account_name   = azurerm_storage_account.archives_ceres.name
  storage_container_name = azurerm_storage_container.db_backups.name
  type                   = "Block"
  content_type           = "text/csv"
  source_content         = local.decoy_crew_csv
}

resource "azurerm_storage_blob" "decoy_ships_csv" {
  name                   = "bulk-exports/ship_registry_2025-05-19.csv"
  storage_account_name   = azurerm_storage_account.archives_ceres.name
  storage_container_name = azurerm_storage_container.db_backups.name
  type                   = "Block"
  content_type           = "text/csv"
  source_content         = local.decoy_ships_csv
}

resource "azurerm_storage_blob" "loot_runner_json" {
  name                   = "automation/tycho-db_export_runner.json"
  storage_account_name   = azurerm_storage_account.archives_ceres.name
  storage_container_name = azurerm_storage_container.db_backups.name
  type                   = "Block"
  content_type           = "application/json"
  source_content         = local.loot_runner_json
}

# tycho-db exporter service principal.

resource "azuread_application" "exporter_sp_app" {
  display_name = "tycho-db-exporter-${var.config.lab_uniq_id}"
}

resource "azuread_service_principal" "exporter_sp" {
  client_id = azuread_application.exporter_sp_app.client_id
}

resource "azuread_service_principal_password" "exporter_sp_password" {
  service_principal_id = azuread_service_principal.exporter_sp.id
  end_date             = var.config.end_date
}

# Read secrets
resource "azurerm_role_assignment" "exporter_sp_ganymede_secrets" {
  scope                = azurerm_key_vault.vault_ganymede.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.exporter_sp.object_id

  depends_on = [
    azurerm_key_vault.vault_ganymede,
    azuread_service_principal.exporter_sp,
  ]
}

# RBAC propagation buffer.
resource "time_sleep" "exporter_sp_rbac_propagation" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.exporter_sp_ganymede_secrets]
}

# The exporter's legitimate reason to be in Ganymede.
resource "azurerm_key_vault_secret" "exporter_storage_cs" {
  name         = "tycho-db-exporter-sa-connection"
  value        = azurerm_storage_account.archives_ceres.primary_connection_string
  key_vault_id = azurerm_key_vault.vault_ganymede.id
  depends_on = [
    azurerm_key_vault.vault_ganymede,
    azurerm_role_assignment.vault_role_assign,
  ]
}
