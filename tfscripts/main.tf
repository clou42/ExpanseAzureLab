variable "config" {
  description = "Configuration values including credentials, keys, and metadata."
  type = object({
    client_ip         = string
    subscription_id   = string
    rocinante_ssh_key = string
    scopuli_ssh_key   = string
    region            = string
    resource_grp_name = string
    scopuli_ssh_user  = string
    tycho_sa_username = string
    tycho_sa_password = string
    lab_uniq_id       = string
    end_date          = string
    verbose           = bool
  })
}
# Create random integer for unique names (used for Ganymede, tycho server, etc.)
resource "random_integer" "ri" {
  min = 10000
  max = 99999
}

# Unguessable suffixes for publicly reachable resources (web app and blob storage)
# so that lab URLs cannot be enumerated or guessed.
resource "random_string" "storage_suffix" {
  length  = 15
  lower   = true
  upper   = false
  numeric  = true
  special = false
}

resource "random_string" "webapp_suffix" {
  length  = 16
  lower   = true
  upper   = false
  numeric  = true
  special = false
}

# Retrieve domain information
data "azuread_domains" "default" {
  only_initial = true
}

# Retrieve tenant information
data "azurerm_client_config" "current" {}

# Create local variables
locals {
  domain_name = data.azuread_domains.default.domains.0.domain_name
  users       = csvdecode(file("${path.module}/users.csv"))
  users_map   = { for user in local.users : user.first_name => user }
  # Read secret timeouts timestamp
  end_date = var.config.end_date
}

# Create Protomolecule (privileged) service pricipal with RBAC
resource "azuread_application" "protomolecule_app" {
  display_name = "Protomolecule-${var.config.lab_uniq_id}"
}

resource "azuread_service_principal" "protomolecule_sp" {
  client_id = azuread_application.protomolecule_app.client_id
}

resource "azuread_service_principal_password" "protomolecule_sp_password" {
  service_principal_id = azuread_service_principal.protomolecule_sp.id
  end_date             = var.config.end_date
}

resource "azurerm_role_assignment" "protomolecule_role_assign" {
  scope                = azurerm_resource_group.res-114.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.protomolecule_sp.object_id
}

# Create SP that will be Tycho DB server admin
resource "azuread_application" "tycho_sa_app" {
  display_name = "Fred Johnson - ${var.config.lab_uniq_id}"
}

resource "azuread_service_principal" "tycho_sa_sp" {
  client_id = azuread_application.tycho_sa_app.client_id
}

resource "azuread_service_principal_password" "tycho_sa_sp_password" {
  service_principal_id = azuread_service_principal.tycho_sa_sp.id
  end_date             = local.end_date
}


# Create users
resource "azuread_user" "users" {
  for_each = { for user in local.users : user.first_name => user }

  user_principal_name = format(
    "%s%s%s@%s",
    substr(lower(each.value.first_name), 0, 1),
    lower(each.value.last_name),
    var.config.lab_uniq_id,
    local.domain_name
  )

  password              = each.value.password
  force_password_change = false

  display_name = "${each.value.first_name} ${var.config.lab_uniq_id} ${each.value.last_name}"
  department   = format("%s-%s", each.value.department, var.config.lab_uniq_id)
  job_title    = format("%s-%s", each.value.job_title, var.config.lab_uniq_id)
}

### Adding Service Principals on the base of the exsisting users:

resource "azuread_application" "app" {
  for_each     = { for user in local.users : user.first_name => user }
  display_name = "${each.value.first_name}-${var.config.lab_uniq_id}-${each.value.last_name}-app"
}

resource "azuread_service_principal" "sp" {
  for_each       = azuread_application.app
  client_id = each.value.client_id
}

resource "azuread_application_password" "pwd" {
  for_each              = azuread_application.app
  application_id = each.value.id
  end_date              = local.end_date
}

## Create directory custom roles

##### TODO: This does only works in higher tier azure subs. Skip it for now.
#  Error: Creating custom directory role "expanse_reader_privileges"
# │
# │   with azuread_custom_directory_role.expanse_reader_privileges,
# │   on main.tf line 112, in resource "azuread_custom_directory_role" "expanse_reader_privileges":
# │  112: resource "azuread_custom_directory_role" "expanse_reader_privileges" {
# │
# │ RoleDefinitionsClient.BaseClient.Post(): unexpected status 403 with OData error: Authorization_RequestDenied: Only companies who have purchased AAD Premium may perform this operation.

# resource "azuread_custom_directory_role" "expanse_reader_privileges" {
#   display_name               = "expanse_reader_privileges"
#   description        = "Allows to read information to enable vectors."
#   enabled = true
#   version = "1.0"

#   permissions { 
#     allowed_resource_actions     = [
#     "microsoft.directory/applications/standard/read",
#     "microsoft.directory/groups/standard/read",
#     "microsoft.directory/users/standard/read",
#     "microsoft.directory/devices/standard/read",
#   ]
#   }
# }

# Create Rocinante RCE role
resource "azurerm_role_definition" "vm_rocinante_exec" {
  name        = "VM_Rocinante_RunCommand_ExtensionsWrite_${var.config.lab_uniq_id}"
  scope       = azurerm_resource_group.res-114.id
  description = "Allows to run Commands and write extensions to the Rocinante VM."

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/runCommand/*",
      "Microsoft.Compute/virtualMachines/extensions/*",
      "Microsoft.Compute/virtualMachines/read"
    ]
    not_actions = []
  }

  assignable_scopes = [
    "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Compute/virtualMachines/Rocinante"
  ]
  depends_on = [
    azurerm_linux_virtual_machine.rocinante,
  ]
}

# Create scopuli RCE role
resource "azurerm_role_definition" "vm_scopuli_exec" {
  name        = "VM_Scopuli_RunCommand_ExtensionsWrite_${var.config.lab_uniq_id}"
  scope       = azurerm_resource_group.res-114.id
  description = "Allows to run Commands and write extensions to the Scopuli VM."

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/runCommand/*",
      "Microsoft.Compute/virtualMachines/extensions/*",
      "Microsoft.Compute/virtualMachines/read"
    ]
    not_actions = []
  }

  assignable_scopes = [
    azurerm_linux_virtual_machine.scopuli.id
  ]
  depends_on = [
    azurerm_linux_virtual_machine.scopuli,
  ]
}

# Unused for now. Could give Scopuli MI SA on tycho instead of read/write only.
# resource "azurerm_role_definition" "sql_tycho_admin_rw" {
#   name        = "SQL_Tycho_admin_rw"
#   scope       = azurerm_resource_group.res-114.id
#   description = "Allows to rread and write the SQL server admin for Tycho."

#   permissions {
#     actions = [
#       "Microsoft.Sql/servers/administrators/read",
#       "Microsoft.Sql/servers/administrators/write"
#     ]
#     not_actions = []
#   }

#   assignable_scopes = [
#     azurerm_mssql_server.tycho.id
#   ]
#   depends_on = [
#     azurerm_mssql_server.tycho,
#   ]
# }

# These custom roles are needed because of a known bug in azure cli, that behaves strange for SSH connections
# TODO: This might be fixed by now, maybe the role is irrelevant.

resource "azurerm_role_definition" "rocinate_nic_access_fix" {
  name        = "Rocinante_nic_ssh_fix_${var.config.lab_uniq_id}"
  scope       = azurerm_resource_group.res-114.id
  description = "Allows to read the nic on Rocinante. This is a fix for azure cli ad ssh issues."

  permissions {
    actions = [
      "Microsoft.Network/networkInterfaces/read",
    ]
    not_actions = []
  }

  assignable_scopes = [
    azurerm_network_interface.res-7.id
  ]
  depends_on = [
    azurerm_network_interface.res-7,
  ]
}

resource "azurerm_role_definition" "rocinate_ip_access_fix" {
  name        = "Rocinante_ip_ssh_fix_${var.config.lab_uniq_id}"
  scope       = azurerm_resource_group.res-114.id
  description = "Allows to read the public-ip on Rocinante. This is a fix for azure cli ad ssh issues."

  permissions {
    actions = [
      "Microsoft.Network/publicIPAddresses/read",
    ]
    not_actions = []
  }

  assignable_scopes = [
    azurerm_public_ip.res-15.id
  ]
  depends_on = [
    azurerm_public_ip.res-15,
  ]
}


# AKS cluster admin role for secretary-general
resource "azurerm_role_definition" "aks_sg_admin" {
  name        = "Expanse_aks_admin_${var.config.lab_uniq_id}"
  scope       = azurerm_resource_group.res-114.id
  description = "Grants cluster‑admin privileges on AKS only"

  permissions {
    actions     = ["Microsoft.ContainerService/managedClusters/*"]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.res-114.id]
}

## Create role bindings

#### This rolebinding is necessary to be able to alter the vault content via terraform!

# Current user is Admin on the Ganymede Vault. This assignment is needed, since Owner access to the subscription does not allow Vault access per defaul - Azure security measure.
resource "azurerm_role_assignment" "vault_role_assign" {
  scope                = azurerm_key_vault.vault_ganymede.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
  depends_on = [
    azurerm_key_vault.vault_ganymede
  ]
}


####

# We use these locals to overcome limitations with dynamically named resources:
locals {
  captain_group_id           = try(azuread_group.job_groups["Captain-${var.config.lab_uniq_id}"].object_id, null)
  pilot_group_id             = try(azuread_group.job_groups["Pilot-${var.config.lab_uniq_id}"].object_id, null)
  crew_group_id              = try(azuread_group.job_groups["Crew-${var.config.lab_uniq_id}"].object_id, null)
  secretary_general_group_id = try(azuread_group.job_groups["Secretary-General-${var.config.lab_uniq_id}"].object_id, null)
}


# Pilots may execute RunCommand and write Extensions on the Rocinante VM
resource "azurerm_role_assignment" "pilot_role_assign" {
  scope                = azurerm_linux_virtual_machine.rocinante.id
  role_definition_id   = azurerm_role_definition.vm_rocinante_exec.role_definition_resource_id
  principal_id         = local.pilot_group_id
  depends_on = [
    azurerm_role_definition.vm_rocinante_exec,
    azurerm_linux_virtual_machine.rocinante
  ]
}

# Captains are Virtual Machine Contributor on the Rocinante VM
resource "azurerm_role_assignment" "captain_role_assign" {
  scope                = azurerm_linux_virtual_machine.rocinante.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = local.captain_group_id
  depends_on = [
    azuread_user.users,
    azurerm_linux_virtual_machine.rocinante
  ]
}


### TODO: Doesn't work because role cannot be defined.
# resource "azuread_directory_role_assignment" "reader_privs_assign" {
#   role_id = azuread_custom_directory_role.expanse_reader_privileges.id
#   principal_object_id       = local.captain_group_id
#   depends_on = [
#     azuread_user.users,
#     azuread_custom_directory_role.expanse_reader_privileges
#   ]
# }

# Crew are allowed normal user login on the Rocinante VM
resource "azurerm_role_assignment" "crew_role_assign" {
  scope                = azurerm_linux_virtual_machine.rocinante.id
  role_definition_name = "Virtual Machine User Login"
  principal_id         = local.crew_group_id
  depends_on = [
    azuread_user.users,
    azurerm_linux_virtual_machine.rocinante
  ]
}

#Give crew the rocinate_nic_access_fix and rocinate_ip_access_fix, to allow SSH access. This is due to a bug in azure cli
# TODO: Might be fixed by now and therefore obsolete.

resource "azurerm_role_assignment" "azure_cli_ssh_fix" {
  scope                = azurerm_network_interface.res-7.id
  role_definition_id = azurerm_role_definition.rocinate_nic_access_fix.role_definition_resource_id
  principal_id         = local.crew_group_id
  depends_on = [
    azuread_user.users,
    azurerm_role_definition.rocinate_nic_access_fix
  ]
}

resource "azurerm_role_assignment" "azure_cli_ssh_fix_ip" {
  scope                = azurerm_public_ip.res-15.id
  role_definition_id = azurerm_role_definition.rocinate_ip_access_fix.role_definition_resource_id
  principal_id         = local.crew_group_id
  depends_on = [
    azuread_user.users,
    azurerm_role_definition.rocinate_ip_access_fix
  ]
}

# KeysToTheScopuli MI is allowed to RunCommands and write Extensions on the Scopuli VM
resource "azurerm_role_assignment" "keystothescopuli_role_assign" {
  scope                = azurerm_linux_virtual_machine.scopuli.id
  role_definition_id = azurerm_role_definition.vm_scopuli_exec.role_definition_resource_id
  principal_id         = azurerm_user_assigned_identity.keystothescopuli.principal_id
  depends_on = [
    azurerm_role_definition.vm_scopuli_exec,
    azurerm_linux_virtual_machine.scopuli,
    azurerm_user_assigned_identity.keystothescopuli
  ]
}

# Inactive for now. Scopuli MI got read/write on tycho-db instead
# # Scopuli MI is allowed to read and write SQL server admin on Tycho TODO
# resource "azurerm_role_assignment" "scopuli_MI_role_assign" {
#   scope = azurerm_mssql_server.tycho.id
#   role_definition_name = "SQL_Tycho_admin_rw_${var.config.lab_uniq_id}"
#   principal_id       = azurerm_linux_virtual_machine.scopuli.identity[0].principal_id
#   depends_on = [
#     azurerm_role_definition.sql_tycho_admin_rw,
#     azurerm_linux_virtual_machine.scopuli,
#   ]
# }



# Crew is Admin on the Ganymede Vault
resource "azurerm_role_assignment" "amos_role_assign" {
  scope                = azurerm_key_vault.vault_ganymede.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = local.crew_group_id
  depends_on = [
    azuread_user.users,
    azurerm_key_vault.vault_ganymede
  ]
}


## Secretary general has * privs on managedClusters
resource "azurerm_role_assignment" "sg_admin_assignment" {
  scope              = azurerm_resource_group.res-114.id
  role_definition_id = azurerm_role_definition.aks_sg_admin.role_definition_resource_id
  principal_id       = local.secretary_general_group_id
  depends_on = [
    azuread_user.users,
  ]
}


## Create Key Vault
resource "azurerm_key_vault" "vault_ganymede" {
  rbac_authorization_enabled  = true
  location                   = azurerm_resource_group.res-114.location
  name                       = "Ganymede-${random_integer.ri.result}"
  resource_group_name        = azurerm_resource_group.res-114.name
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

### Create certificate in vault
# resource "azurerm_key_vault_certificate" "res-8" {
#   key_vault_id = azurerm_key_vault.vault_ganymede.id
#   name         = "SecretCertificate"
#   certificate_policy {
#     issuer_parameters {
#       name = "Self"
#     }
#     key_properties {
#       exportable = true
#       key_type   = "RSA"
#       reuse_key  = true
#       key_size   = 2048
#     }
#     lifetime_action {
#       action {
#         action_type = "AutoRenew"
#       }
#       trigger {
#         lifetime_percentage = 80
#       }
#     }
#     secret_properties {
#       content_type = "application/x-pkcs12"
#     }
#     x509_certificate_properties {
#       # Server Authentication = 1.3.6.1.5.5.7.3.1
#       # Client Authentication = 1.3.6.1.5.5.7.3.2
#       extended_key_usage = ["1.3.6.1.5.5.7.3.1"]

#       key_usage = [
#         "cRLSign",
#         "dataEncipherment",
#         "digitalSignature",
#         "keyAgreement",
#         "keyCertSign",
#         "keyEncipherment",
#       ]

#       subject_alternative_names {
#         dns_names = ["vault.test.here"]
#       }

#       subject            = "CN=Ganymede"
#       validity_in_months = 12
#     }
#   }
#   depends_on = [
#     azurerm_key_vault.vault_ganymede,
#     azurerm_role_assignment.vault_role_assign
#   ]
# }

### Create RSA key in vault
resource "azurerm_key_vault_key" "res-9" {
  key_opts     = ["sign", "verify", "wrapKey", "unwrapKey", "encrypt", "decrypt"]
  key_size     = 2048
  key_type     = "RSA"
  key_vault_id = azurerm_key_vault.vault_ganymede.id
  name         = "RsaKey"
  depends_on = [
    azurerm_key_vault.vault_ganymede,
    azurerm_role_assignment.vault_role_assign
  ]
}

### Create a secret in vault
resource "azurerm_key_vault_secret" "res-10" {
  key_vault_id = azurerm_key_vault.vault_ganymede.id
  name         = "Map"
  value        = "Th$s$sS3cr3t!"
  depends_on = [
    azurerm_key_vault.vault_ganymede,
    azurerm_role_assignment.vault_role_assign
  ]
}

## More secrets are defined down below for the AKS cluster.

## Create storage account 

resource "azurerm_storage_account" "storage_labpallas" {
  account_replication_type         = "LRS"
  account_tier                     = "Standard"
  cross_tenant_replication_enabled = false
  location                         = azurerm_resource_group.res-114.location
  name                             = "labpallas${random_string.storage_suffix.result}"
  resource_group_name              = azurerm_resource_group.res-114.name
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

### Create storage container

resource "azurerm_storage_container" "pallas" {
  name                  = "pallas-${random_string.storage_suffix.result}"
  storage_account_id  = azurerm_storage_account.storage_labpallas.id
  container_access_type = "blob"
}

### Create public storage blob with some resources

resource "azurerm_storage_blob" "pallasblob" {
  for_each = fileset(path.module, "blob_resources/*")

  name                   = each.key
  storage_account_name   = azurerm_storage_account.storage_labpallas.name
  storage_container_name = azurerm_storage_container.pallas.name
  type                   = "Block"
  source                 = each.key
}

# Compose Alex' credentials JSON
locals {
  alex_blob_json = jsonencode({
    client_id     = azuread_application.app["Alex"].client_id
    client_secret = nonsensitive(azuread_application_password.pwd["Alex"].value)
    tenant_id     = data.azurerm_client_config.current.tenant_id
  })
}

# Write the JSON as a blob at the container root (credentials.json)
resource "azurerm_storage_blob" "alex_credentials_json" {
  name                   = "credentials.json"
  storage_account_name   = azurerm_storage_account.storage_labpallas.name
  storage_container_name = azurerm_storage_container.pallas.name
  type                   = "Block"
  content_type           = "application/json"
  source_content         = local.alex_blob_json

  depends_on = [
    azuread_application_password.pwd["Alex"],
    azurerm_storage_container.pallas
  ]
}


## Inactive and unused for now
## Create app

# Create the Linux App Service Plan
# resource "azurerm_service_plan" "app_phoebe_serviceplan" {
#   name                = "webapp-phoebe-serviceplan-${random_integer.ri.result}"
#   location            = azurerm_resource_group.res-114.location
#   resource_group_name = azurerm_resource_group.res-114.name
#   os_type             = "Linux"
#   sku_name            = "B1"
# }

# # Create the web app, pass in the App Service Plan ID
# resource "azurerm_linux_web_app" "webapp-phoebe" {
#   name                  = "webapp-phoebe-${random_integer.ri.result}"
#   location              = azurerm_resource_group.res-114.location
#   resource_group_name   = azurerm_resource_group.res-114.name
#   service_plan_id       = azurerm_service_plan.app_phoebe_serviceplan.id
#   https_only            = true
#   site_config { 
#     minimum_tls_version = "1.2"
#   }
# }

# #  Deploy code from a public GitHub repo (this is a placeholder for now)
# resource "azurerm_app_service_source_control" "sourcecontrol" {
#   app_id             = azurerm_linux_web_app.webapp-phoebe.id
#   repo_url           = "https://github.com/Azure-Samples/nodejs-docs-hello-world"
#   branch             = "master"
#   use_manual_integration = true
#   use_mercurial      = false
# }

### Tycho Terminal Web App

# ---------- App Service Plan (Linux) ----------
resource "azurerm_service_plan" "app_tycho_terminal_serviceplan" {
  name                = "webapp-tycho-terminal-serviceplan-${random_string.webapp_suffix.result}"
  location            = azurerm_resource_group.res-114.location
  resource_group_name = azurerm_resource_group.res-114.name
  os_type             = "Linux"
  sku_name            = "B1"
}

# Local zip of the tycho-terminal webapp. Latest version can be downloaded from https://github.com/clou42/tycho-terminal-webapp

variable "local_zip_path" {
  type        = string
  description = "Path to the prebuilt release zip on the local machine running Terraform"
  default     = "tycho_terminal/tycho-terminal.zip" # adjust as needed
}

# Hash of the local file; used to force app restart on change
locals {
  local_pkg_sha256 = filesha256(var.local_zip_path)
}

# Upload zip to storage
resource "azurerm_storage_blob" "tycho_package" {
  name                   = "tycho-terminal.zip"
  storage_account_name   = azurerm_storage_account.storage_labpallas.name
  storage_container_name = azurerm_storage_container.pallas.name
  type                   = "Block"
  content_type           = "application/zip"

  source = var.local_zip_path

  depends_on = [
    azurerm_storage_account.storage_labpallas,
    azurerm_storage_container.pallas
  ]
}

# Create a read-only SAS for that blob
data "azurerm_storage_account_sas" "tycho_pkg" {
  connection_string = azurerm_storage_account.storage_labpallas.primary_connection_string
  https_only        = true
  start             = timestamp()
  expiry            = timeadd(timestamp(), "120h") # 5 days; adjust as needed

  services {
    blob  = true
    queue = false
    file  = false
    table = false
  }

  resource_types {
    service   = false
    container = false
    object    = true
  }

  permissions {
    read    = true
    add     = false
    create  = false
    write   = false
    delete  = false
    list    = false
    update  = false
    process = false
    tag     = false
    filter  = false
  }

  depends_on = [ azurerm_storage_blob.tycho_package ]
}

locals {
  pkg_sas_url            = "https://${azurerm_storage_account.storage_labpallas.name}.blob.core.windows.net/${azurerm_storage_container.pallas.name}/${azurerm_storage_blob.tycho_package.name}${data.azurerm_storage_account_sas.tycho_pkg.sas}"
  pkg_sas_url_sensitive  = sensitive(local.pkg_sas_url) # avoid printing the SAS in plans
}

# Point the Web App to the SAS URL (Run-From-Package)
resource "azurerm_linux_web_app" "tycho-terminal" {
  name                = "tycho-terminal-${random_string.webapp_suffix.result}"
  location            = azurerm_resource_group.res-114.location
  resource_group_name = azurerm_resource_group.res-114.name
  service_plan_id     = azurerm_service_plan.app_tycho_terminal_serviceplan.id

  site_config {
    always_on        = true
    app_command_line = "node app.js"
    application_stack { node_version = "22-lts" }

    # Restrict access to client_ip only (same whitelist as DB and VM NSGs)
    dynamic "ip_restriction" {
      for_each = var.config.client_ip != "" ? [1] : []
      content {
        ip_address = "${var.config.client_ip}/32"
        action     = "Allow"
        name       = "AllowClientIP"
        priority   = 100
      }
    }
    # Restrict SCM (Kudu) to same IP so deployment/config is not exposed
    dynamic "scm_ip_restriction" {
      for_each = var.config.client_ip != "" ? [1] : []
      content {
        ip_address = "${var.config.client_ip}/32"
        action     = "Allow"
        name       = "AllowClientIP"
        priority   = 100
      }
    }
  }

  identity { type = "SystemAssigned" }

  app_settings = {
    WEBSITE_RUN_FROM_PACKAGE     = local.pkg_sas_url_sensitive
    WEBSITE_NODE_DEFAULT_VERSION = "~22"

    # Restart the app when the local ZIP changes
    PACKAGE_HASH                 = local.local_pkg_sha256
    # Optional one-time trigger to force remount immediately:
    # DEPLOYMENT_TRIGGER          = timestamp()
    # tell db.service.js to use SQL in prod
    DB_PROVIDER                  = "mssql"

    # host/db for both MI & CS
    AZURE_SQL_SERVER             = azurerm_mssql_server.tycho.fully_qualified_domain_name
    AZURE_SQL_DATABASE           = azurerm_mssql_database.tycho-db.name
    AZURE_SQL_PORT               = "1433"

    # pick passwordless on App Service
    AZURE_SQL_AUTHENTICATIONTYPE = "azure-active-directory-default"

    # optional: leave CS path available; if set, it wins over MI
    # SQLSERVER_CONNECTION_STRING = "Server=tcp:${azurerm_mssql_server.tycho.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.tycho-db.name};User ID=...;Password=...;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

  }

  logs {
    application_logs { file_system_level = "Verbose" }
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  depends_on = [ azurerm_storage_blob.tycho_package ]
}


### END tycho-terminal

## Set authentication SSH key for Rocinante VM
resource "azurerm_ssh_public_key" "rocinante-sshkey" {
  location            = azurerm_resource_group.res-114.location
  name                = "RocinanteSSHKey"
  public_key          = var.config.rocinante_ssh_key
  resource_group_name = azurerm_resource_group.res-114.name
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

## Set authentication SSH key for Scopuli VM
resource "azurerm_ssh_public_key" "scopuli-sshkey" {
  location            = azurerm_resource_group.res-114.location
  name                = "ScopuliSSHKey"
  public_key          = var.config.scopuli_ssh_key
  resource_group_name = azurerm_resource_group.res-114.name
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

## Create Rocinante VM
resource "azurerm_linux_virtual_machine" "rocinante" {
  admin_username        = "kelly"
  location              = azurerm_resource_group.res-114.location
  name                  = "Rocinante"
  network_interface_ids = ["/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/networkInterfaces/rocinante796"]
  patch_mode            = "AutomaticByPlatform"
  reboot_setting        = "IfRequired"
  resource_group_name   = azurerm_resource_group.res-114.name
  size                  = "Standard_D2s_v3"
  additional_capabilities {
  }
  admin_ssh_key {
    public_key = azurerm_ssh_public_key.rocinante-sshkey.public_key
    username   = "kelly"
  }
  boot_diagnostics {
  }
  identity {
    identity_ids = ["/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/KeysToTheScopuli_${var.config.lab_uniq_id}"]
    type         = "UserAssigned"
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    offer     = "0001-com-ubuntu-server-focal"
    publisher = "canonical"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
  depends_on = [
    azurerm_user_assigned_identity.keystothescopuli,
    azurerm_network_interface.res-7,
  ]
}
### Get some loot into Rocinante (AWS account creds)

# Define loot. By default this is garbage.
# TODO: Allow to define real secrets via the terraform.tfvars file.

locals {
aws_secrets = <<-SECRETS
[default]
aws_access_key_id=ASIAIOSFODNN7EXAMPLE
aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
aws_session_token = IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE

[user1]
aws_access_key_id=ASIAI44QH8DHBEXAMPLE
aws_secret_access_key=je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY
aws_session_token = fcZib3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE
SECRETS
aws_secrets_b64 = base64encode(local.aws_secrets)
}

resource "azurerm_virtual_machine_extension" "rocinante_loot_provision" {
  name                 = "rocinante_loot_provision"
  virtual_machine_id   = azurerm_linux_virtual_machine.rocinante.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = <<SETTINGS
{
  "commandToExecute": "bash -c 'export DEBIAN_FRONTEND=\"noninteractive\" && mkdir /home/kelly/.aws && echo \"${local.aws_secrets_b64}\" | base64 -d > /home/kelly/.aws/credentials && chown -R kelly: /home/kelly/.aws'"
}
SETTINGS

  depends_on = [
    azurerm_linux_virtual_machine.rocinante
  ]
}


### Attach AADSSH extension to Rocinante
resource "azurerm_virtual_machine_extension" "res-4" {
  auto_upgrade_minor_version = true
  name                       = "AADSSHLoginForLinux"
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  virtual_machine_id         = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Compute/virtualMachines/Rocinante"
  depends_on = [
    azurerm_linux_virtual_machine.rocinante,
  ]
}

## Create Scopuli VM
resource "azurerm_linux_virtual_machine" "scopuli" {
  admin_username        = "darren"
  location              = azurerm_resource_group.res-114.location
  name                  = "Scopuli"
  network_interface_ids = ["/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/networkInterfaces/scopuli337_z1"]
  patch_mode            = "AutomaticByPlatform"
  reboot_setting        = "IfRequired"
  resource_group_name   = azurerm_resource_group.res-114.name
  size                  = "Standard_D2s_v3"
  additional_capabilities {
  }
  admin_ssh_key {
    public_key = azurerm_ssh_public_key.scopuli-sshkey.public_key
    username   = var.config.scopuli_ssh_user
  }
  boot_diagnostics {
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.scopuli_sql_provisioner.id]
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    offer     = "0001-com-ubuntu-server-focal"
    publisher = "canonical"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
  depends_on = [
    azurerm_network_interface.res-9,
  ]
}

## Create user assigned managed identity "keystothescopuli"
resource "azurerm_user_assigned_identity" "keystothescopuli" {
  location            = azurerm_resource_group.res-114.location
  name                = "KeysToTheScopuli_${var.config.lab_uniq_id}"
  resource_group_name = azurerm_resource_group.res-114.name
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

## Create network interface for the Rocinante VM
resource "azurerm_network_interface" "res-7" {
  location            = azurerm_resource_group.res-114.location
  name                = "rocinante796"
  resource_group_name = azurerm_resource_group.res-114.name
  ip_configuration {
    name                          = "ipconfig1"
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/publicIPAddresses/Rocinante-ip"
    subnet_id                     = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/virtualNetworks/Space-vnet/subnets/default"
  }
  depends_on = [
    azurerm_public_ip.res-15,
    azurerm_subnet.res-18,
  ]
}

## Assign the rocinante NIC to the NSG "Space-nsg"
resource "azurerm_network_interface_security_group_association" "res-8" {
  network_interface_id      = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/networkInterfaces/rocinante796"
  network_security_group_id = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/networkSecurityGroups/Space-nsg"
  depends_on = [
    azurerm_network_interface.res-7,
    azurerm_network_security_group.res-11,
  ]
}

## Create network interface for the Scopuli VM
resource "azurerm_network_interface" "res-9" {
  location            = azurerm_resource_group.res-114.location
  name                = "scopuli337_z1"
  resource_group_name = azurerm_resource_group.res-114.name
  ip_configuration {
    name                          = "ipconfig1"
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/publicIPAddresses/Scopuli-ip"
    subnet_id                     = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/virtualNetworks/Space-vnet/subnets/default"
  }
  depends_on = [
    azurerm_public_ip.res-16,
    azurerm_subnet.res-18,
  ]
}

## Assign the scopuli NIC to the NSG "Space-nsg"
resource "azurerm_network_interface_security_group_association" "res-10" {
  network_interface_id      = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/networkInterfaces/scopuli337_z1"
  network_security_group_id = "/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.Network/networkSecurityGroups/Space-nsg"
  depends_on = [
    azurerm_network_interface.res-9,
    azurerm_network_security_group.res-11,
  ]
}

## Create "space-nsg" NetworkSecurityGroup
resource "azurerm_network_security_group" "res-11" {
  location            = azurerm_resource_group.res-114.location
  name                = "Space-nsg"
  resource_group_name = azurerm_resource_group.res-114.name
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

## Define the network security roles, that allows full network access to the Space-nsg only from the defined "client_ip" (in terraform.tfvars)
resource "azurerm_network_security_rule" "res-12" {
  access                      = "Allow"
  destination_address_prefix  = "*"
  destination_port_range      = "*"
  direction                   = "Inbound"
  name                        = "SSH"
  network_security_group_name = "Space-nsg"
  priority                    = 300
  protocol                    = "Tcp"
  resource_group_name         = azurerm_resource_group.res-114.name
  source_address_prefix       = var.config.client_ip
  source_port_range           = "*"
  depends_on = [
    azurerm_network_security_group.res-11,
  ]
}

## Create public IP for the rocinante VM
resource "azurerm_public_ip" "res-15" {
  allocation_method   = "Static"
  location            = azurerm_resource_group.res-114.location
  name                = "Rocinante-ip"
  resource_group_name = azurerm_resource_group.res-114.name
  sku                 = "Standard"
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

## Create public IP for the scopuli VM
resource "azurerm_public_ip" "res-16" {
  allocation_method   = "Static"
  location            = azurerm_resource_group.res-114.location
  name                = "Scopuli-ip"
  resource_group_name = azurerm_resource_group.res-114.name
  sku                 = "Standard"
  zones               = ["1"]
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

## Create azure virtual network "Space-vnet"
resource "azurerm_virtual_network" "res-17" {
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.res-114.location
  name                = "Space-vnet"
  resource_group_name = azurerm_resource_group.res-114.name
  depends_on = [
    azurerm_resource_group.res-114,
  ]
}

## Create a subnet in the Space-vnet
resource "azurerm_subnet" "res-18" {
  address_prefixes     = ["10.0.0.0/24"]
  name                 = "default"
  resource_group_name  = azurerm_resource_group.res-114.name
  virtual_network_name = "Space-vnet"
  depends_on = [
    azurerm_virtual_network.res-17,
  ]
}



## TODO: Creating EROS DB - disabled to save cost.

# ## Create MSSQL server "eros"
# resource "azurerm_mssql_server" "eros" {
#   administrator_login = "proto"
#   administrator_login_password = "P@ssw0rd!"
#   location            = azurerm_resource_group.res-114.location
#   name                = "eros-${random_integer.ri.result}"
#   resource_group_name = azurerm_resource_group.res-114.name
#   version             = "12.0"
#   azuread_administrator {
#     login_username = "Protomolecule"
#     object_id      = azuread_application.protomolecule_app.client_id
#   }
#   # identity {
#   #   identity_ids = ["/subscriptions/${var.config.subscription_id}/resourceGroups/${azurerm_resource_group.res-114.name}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/KeysToTheScopuli"]
#   #   type         = "UserAssigned"
#   # }
#   depends_on = [
#     azurerm_user_assigned_identity.keystothescopuli,
#   ]
# }

# ## Create the database "eros-db" on the "eros" MSSQL server
# resource "azurerm_mssql_database" "res-31" {
#   name      = "eros-db"
#   server_id = azurerm_mssql_server.eros.id
#   depends_on = [
#     azurerm_mssql_server.eros,
#   ]
# }

# ## Disable extended auditing policy on eros-db
# resource "azurerm_mssql_database_extended_auditing_policy" "res-37" {
#   database_id            = azurerm_mssql_database.res-31.id
#   enabled                = false
#   log_monitoring_enabled = false
#   depends_on = [
#     azurerm_mssql_database.res-31,
#   ]
# }

# ## Disable microsoft support auditing policy on "eros" MSSQL server
# resource "azurerm_mssql_server_microsoft_support_auditing_policy" "res-52" {
#   enabled                = false
#   log_monitoring_enabled = false
#   server_id              = azurerm_mssql_server.eros.id
#   depends_on = [
#     azurerm_mssql_server.eros,
#     azurerm_resource_group.res-114
#   ]
# }
# resource "azurerm_mssql_server_transparent_data_encryption" "res-53" {
#   server_id = azurerm_mssql_server.eros.id
#   depends_on = [
#     azurerm_mssql_server.eros,
#   ]
# }
# resource "azurerm_mssql_server_extended_auditing_policy" "res-54" {
#   enabled                = false
#   log_monitoring_enabled = false
#   server_id              = azurerm_mssql_server.eros.id
#   depends_on = [
#     azurerm_mssql_server.eros,
#   ]
# }

# ## Allow wildcard access from all Azure ips (this is like checking the corresponding checkbox in the UI)
# resource "azurerm_mssql_firewall_rule" "res-55" {
#   end_ip_address   = "0.0.0.0"
#   name             = "AllowAllWindowsAzureIps"
#   server_id        = azurerm_mssql_server.eros.id
#   start_ip_address = "0.0.0.0"
#   depends_on = [
#     azurerm_mssql_server.eros,
#   ]
# }


# ## Create a firewall rule to allow the client_ip from terraform.tfvars to connect to the MSSQL server eros
# resource "azurerm_mssql_firewall_rule" "res-58" {
#   end_ip_address   = var.config.client_ip
#   name             = "ClientIp-public-IP"
#   server_id        = azurerm_mssql_server.eros.id
#   start_ip_address = var.config.client_ip
#   depends_on = [
#     azurerm_mssql_server.eros,
#   ]
# }
# resource "azurerm_mssql_server_security_alert_policy" "eros_alter_policy" {
#   resource_group_name = azurerm_resource_group.res-114.name
#   server_name         = azurerm_mssql_server.eros.name
#   state               = "Disabled"
#   depends_on = [
#     azurerm_mssql_server.eros,
#   ]
# }

resource "azurerm_mssql_virtual_network_rule" "tycho_sql_vnet_rule" {
  name                                 = "example-sql-vnet-rule"
  server_id                            = azurerm_mssql_server.tycho.id
  subnet_id                            = azurerm_subnet.res-18.id
  ignore_missing_vnet_service_endpoint = true
  depends_on = [
    azurerm_mssql_server.tycho
  ]
}

## Create MSSQL server tycho
resource "azurerm_mssql_server" "tycho" {
  administrator_login          = var.config.tycho_sa_username
  administrator_login_password = var.config.tycho_sa_password
  location                     = azurerm_resource_group.res-114.location
  name                         = "tycho-${random_integer.ri.result}"
  resource_group_name          = azurerm_resource_group.res-114.name
  version                      = "12.0"
  azuread_administrator {
    login_username = "Fred Johnson"
    object_id      = azuread_service_principal.tycho_sa_sp.object_id
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.tycho_directory_reader.id]
  }
  primary_user_assigned_identity_id = azurerm_user_assigned_identity.tycho_directory_reader.id
  depends_on = [
    azurerm_resource_group.res-114,
    azuread_application.tycho_sa_app,
    azurerm_user_assigned_identity.tycho_directory_reader
  ]
}

## Create DB "tycho-db" on MSSQL server tycho
# Cost-optimized single DB (Serverless)
resource "azurerm_mssql_database" "tycho-db" {
  name      = "tycho-db"
  server_id = azurerm_mssql_server.tycho.id

  # Serverless GP: max 1 vCore, bill to zero when paused
  sku_name                    = "GP_S_Gen5_1"    # GP = General Purpose, S = Serverless
  min_capacity                = 1              # vCores while active (min)
  auto_pause_delay_in_minutes = 60               # pause after 60 min idle
  max_size_gb                 = 8               # keep storage small; you pay for the cap

  # Turn off extras
  zone_redundant = false
  read_scale     = false

  short_term_retention_policy {
    retention_days = 7                           # minimum, lowers backup storage
  }

  depends_on = [
    azurerm_mssql_server.tycho,
    azurerm_resource_group.res-114
  ]

  lifecycle {
    prevent_destroy = false                       # avoid accidental drops
  }
}

resource "azurerm_mssql_database_extended_auditing_policy" "res-90" {
  database_id            = azurerm_mssql_database.tycho-db.id
  enabled                = false
  log_monitoring_enabled = false
  depends_on = [
    azurerm_mssql_database.tycho-db,
    azurerm_resource_group.res-114
  ]
}
resource "azurerm_mssql_server_microsoft_support_auditing_policy" "res-96" {
  enabled                = false
  log_monitoring_enabled = false
  server_id              = azurerm_mssql_server.tycho.id
  depends_on = [
    azurerm_mssql_server.tycho,
  ]
}
resource "azurerm_mssql_server_transparent_data_encryption" "res-97" {
  server_id = azurerm_mssql_server.tycho.id
  depends_on = [
    azurerm_mssql_server.tycho,
  ]
}
resource "azurerm_mssql_server_extended_auditing_policy" "res-98" {
  enabled                = false
  log_monitoring_enabled = false
  server_id              = azurerm_mssql_server.tycho.id
  depends_on = [
    azurerm_mssql_server.tycho,
  ]
}

## Allow wildcard access from all Azure ips (this is like checking the corresponding checkbox in the UI)
resource "azurerm_mssql_firewall_rule" "res-99" {
  end_ip_address   = "0.0.0.0"
  name             = "AllowAllWindowsAzureIps"
  server_id        = azurerm_mssql_server.tycho.id
  start_ip_address = "0.0.0.0"
  depends_on = [
    azurerm_mssql_server.tycho,
  ]
}

## Create a firewall rule to allow the client_ip from terraform.tfvars to connect to the MSSQL server tycho
resource "azurerm_mssql_firewall_rule" "res-100" {
  end_ip_address   = var.config.client_ip
  name             = "ClientIp-public-IP"
  server_id        = azurerm_mssql_server.tycho.id
  start_ip_address = var.config.client_ip
  depends_on = [
    azurerm_mssql_server.tycho,
  ]
}
resource "azurerm_mssql_server_security_alert_policy" "res-105" {
  resource_group_name = azurerm_resource_group.res-114.name
  server_name         = azurerm_mssql_server.tycho.name
  state               = "Disabled"
  depends_on = [
    azurerm_mssql_server.tycho,
  ]
}

### SQL provisioning block

# Managed Identity for SQL provisioning
resource "azurerm_user_assigned_identity" "scopuli_sql_provisioner" {
  name                = "scopuli-sql-provisioner_${var.config.lab_uniq_id}"
  location            = azurerm_resource_group.res-114.location
  resource_group_name = azurerm_resource_group.res-114.name
}

# Grant managed identity Storage Blob Data Reader on the scripts container
resource "azurerm_role_assignment" "scopuli_storage_blob_data_reader" {
  principal_id         = azurerm_user_assigned_identity.scopuli_sql_provisioner.principal_id
  role_definition_name = "Storage Blob Data Reader"
  scope                = azurerm_storage_account.storage_labpallas.id
}

# Managed Identity for SQL server directory read. If we want to to create AD users in SQL and use a SP for that the SQL server cannot
# query for object data. This is because normally the server assumes the roles of the logged in user for their operations -> but SPs cannot be assumend. Therefore the SQL server needs permissions to read the AD itself
resource "azurerm_user_assigned_identity" "tycho_directory_reader" {
  name                = "tycho-directory-reader_${var.config.lab_uniq_id}"
  location            = azurerm_resource_group.res-114.location
  resource_group_name = azurerm_resource_group.res-114.name
}

# Wait for the managed identity's service principal to propagate in Azure AD before assigning directory role
resource "time_sleep" "tycho_directory_reader_propagation" {
  create_duration = "60s"
  depends_on     = [azurerm_user_assigned_identity.tycho_directory_reader]
}

resource "azuread_directory_role" "directory_readers" {
  display_name = "Directory Readers"
}

resource "azuread_directory_role_assignment" "tycho_directory_reader_assignment" {
  principal_object_id = azurerm_user_assigned_identity.tycho_directory_reader.principal_id
  role_id             = azuread_directory_role.directory_readers.template_id
  depends_on          = [time_sleep.tycho_directory_reader_propagation]
}


## 1. Grant the scopuli MI db permissions, 
## 2. Provision tycho-db from blob_resources/expanse_init.sql
## 3. Grant the tycho-terminal webapp MI db reader and writer on tycho-db.
## 4. Insert Chrisjen's SP credentials into tycho-db (which then also becomes loot on the Scopuli)

# Chrisjen DB Manupulation: 
# Create locals for Chrisjen auth data:
locals {
  chrisjen_app_id          = azuread_application.app["Chrisjen"].client_id
  chrisjen_app_secret      = nonsensitive(azuread_application_password.pwd["Chrisjen"].value)
  # Escape single quotes in case the secret contains any
  chrisjen_app_secret_sql  = replace(local.chrisjen_app_secret, "'", "''")

  chrisjen_sql_string = format(
    "UPDATE dbo.espionage_credentials SET app_id = '%s', secret = '%s', tenant_id = '%s' WHERE subject_name = N'%s';",
    local.chrisjen_app_id,
    local.chrisjen_app_secret_sql,
    data.azurerm_client_config.current.tenant_id,
    "Chrisjen Avasarala"
  )

  # Base64 for safe transport through JSON + bash + echo
  chrisjen_sql_b64 = base64encode(local.chrisjen_sql_string)
}

# This is messy but it works. Actually this is the only way I found to deploy SQL in terraform only without using local resources. Also gives some hints on certain attacks on azure envs ;)
resource "azurerm_virtual_machine_extension" "scopuli_sql_provision" {
  name                 = "scopuli_sql_provision"
  virtual_machine_id   = azurerm_linux_virtual_machine.scopuli.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = <<SETTINGS
{
  "commandToExecute": "bash -c 'export DEBIAN_FRONTEND=\"noninteractive\" && apt-get update && apt-get install -y wget curl apt-transport-https gnupg jq && curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && curl https://packages.microsoft.com/config/ubuntu/20.04/prod.list > /etc/apt/sources.list.d/msprod.list && apt-get update && apt-get install sqlcmd && curl \"https://${azurerm_storage_account.storage_labpallas.name}.blob.core.windows.net/${azurerm_storage_container.pallas.name}/blob_resources/expanse_init.sql\" -o /tmp/expanse_init.sql && echo \"CREATE USER [${azurerm_user_assigned_identity.scopuli_sql_provisioner.name}] FROM EXTERNAL PROVIDER; ALTER ROLE db_owner ADD MEMBER [${azurerm_user_assigned_identity.scopuli_sql_provisioner.name}];\" > /tmp/grant_mi.sql && sqlcmd -S tcp:${azurerm_mssql_server.tycho.fully_qualified_domain_name} -d ${azurerm_mssql_database.tycho-db.name} --authentication-method ActiveDirectoryServicePrincipal -U ${azuread_application.tycho_sa_app.client_id} -P ${azuread_service_principal_password.tycho_sa_sp_password.value} -i /tmp/grant_mi.sql && curl -H \"Metadata:true\" \"http://169.254.169.254/metadata/identity/oauth2/token?resource=https://database.windows.net/&api-version=2018-02-01\" | jq -r .access_token > access.tkn && sqlcmd -S tcp:${azurerm_mssql_server.tycho.fully_qualified_domain_name} -d ${azurerm_mssql_database.tycho-db.name} --authentication-method ActiveDirectoryManagedIdentity -I -i /tmp/expanse_init.sql -P access.tkn && echo \"CREATE USER [${azurerm_linux_web_app.tycho-terminal.name}] FROM EXTERNAL PROVIDER;; ALTER ROLE db_datareader ADD MEMBER [${azurerm_linux_web_app.tycho-terminal.name}]; ALTER ROLE db_datawriter ADD MEMBER [${azurerm_linux_web_app.tycho-terminal.name}];\" > /tmp/grant_tycho-terminal-mi.sql && sqlcmd -S tcp:${azurerm_mssql_server.tycho.fully_qualified_domain_name} -d ${azurerm_mssql_database.tycho-db.name} --authentication-method ActiveDirectoryManagedIdentity -I -i /tmp/grant_tycho-terminal-mi.sql -P access.tkn && echo \"${local.chrisjen_sql_b64}\" | base64 -d > /tmp/insert-SG-credentials.sql && sqlcmd -S tcp:${azurerm_mssql_server.tycho.fully_qualified_domain_name} -d ${azurerm_mssql_database.tycho-db.name} --authentication-method ActiveDirectoryManagedIdentity -I -i /tmp/insert-SG-credentials.sql -P access.tkn'"
}
SETTINGS

  depends_on = [
    azurerm_linux_virtual_machine.scopuli,
    azurerm_user_assigned_identity.scopuli_sql_provisioner,
    azurerm_storage_account.storage_labpallas,
    azurerm_mssql_server.tycho,
    azurerm_mssql_database.tycho-db,
    azurerm_linux_web_app.tycho-terminal
  ]
}


### AKS CLUSTER

resource "azurerm_kubernetes_cluster" "earth_fleet" {
  name                = "un_fleet_${var.config.lab_uniq_id}"
  location            = var.config.region
  resource_group_name = var.config.resource_grp_name
  dns_prefix          = "unfleet${var.config.lab_uniq_id}"
  kubernetes_version  = "1.33"

  default_node_pool {
    name                 = "core${lower(var.config.lab_uniq_id)}"
    vm_size              = "Standard_B4ms"
    node_count           = 1
    orchestrator_version = "1.33"
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }
  local_account_disabled = false
  # AAD‑managed RBAC: Secretary‑General group = cluster‑admin
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    admin_group_object_ids = [basename(local.secretary_general_group_id)]
  }

  # Allows pods to mount secrets from Key-Vault
  key_vault_secrets_provider { secret_rotation_enabled = false }

}

#########################################
#-----  SECRETS STORED IN GANYMEDE ------
#########################################


## These steps are needed to prevent a race condition where the role assign is done
## but not yet propagated:

data "azurerm_kubernetes_cluster" "earth_fleet_identity" {
  name                = azurerm_kubernetes_cluster.earth_fleet.name
  resource_group_name = var.config.resource_grp_name

  depends_on = [azurerm_kubernetes_cluster.earth_fleet]
}

resource "azurerm_role_assignment" "aks_kv_secrets_user" {
  scope                = azurerm_key_vault.vault_ganymede.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_kubernetes_cluster.earth_fleet_identity.kubelet_identity[0].object_id

  depends_on = [
    azurerm_key_vault.vault_ganymede,
    azurerm_kubernetes_cluster.earth_fleet
  ]
}

data "azurerm_resources" "verify_aks_kv_assignment" {
  resource_group_name = var.config.resource_grp_name
  type                = "Microsoft.Authorization/roleAssignments"
  required_tags       = {}
  depends_on          = [azurerm_role_assignment.aks_kv_secrets_user]
}


## Put the protomolecule SP info into the key vault
resource "azurerm_key_vault_secret" "protomolecule_key" {
  name         = "Protomolecule-App-Secret"
  value        = azuread_service_principal_password.protomolecule_sp_password.value
  key_vault_id = azurerm_key_vault.vault_ganymede.id
  depends_on = [
    data.azurerm_resources.verify_aks_kv_assignment
  ]
}

resource "azurerm_key_vault_secret" "protomolecule_id" {
  name         = "Protomolecule-App-ID"
  value        = azuread_application.protomolecule_app.client_id
  key_vault_id = azurerm_key_vault.vault_ganymede.id
  depends_on = [
    data.azurerm_resources.verify_aks_kv_assignment
  ]
}

resource "azurerm_key_vault_secret" "tycho_conn" {
  name         = "tycho-fact"
  value        = "Fred is cool."
  key_vault_id = azurerm_key_vault.vault_ganymede.id
  depends_on = [
    data.azurerm_resources.verify_aks_kv_assignment
  ]
}


## IN-CLUSTER secrets


provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.earth_fleet.kube_admin_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.earth_fleet.kube_admin_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.earth_fleet.kube_admin_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.earth_fleet.kube_admin_config[0].cluster_ca_certificate)
}


# 1) Protomolecule app
resource "kubernetes_secret_v1" "protomolecule_service_principal" {
  metadata {
    name      = "protomolecule-app-id"
    namespace = "default"
    labels = {
      faction = "unknown"
      origin  = "unknown"
    }
  }

  data = {
    app_id = azurerm_key_vault_secret.protomolecule_id.value
    secret = azurerm_key_vault_secret.protomolecule_key.value
  }
  type = "Opaque"
}

# 2) Tycho fact secret plus some file.
resource "kubernetes_secret_v1" "tycho_fact" {
  metadata {
    name      = "tycho-fact"
    namespace = "default"
    labels = {
      faction = "OPA"
      origin  = "tycho"
    }
  }

  data = {
    "fact.txt"    = azurerm_key_vault_secret.tycho_conn.value
    "warning.txt" = "DON’T touch the blue goo!"
  }
  type = "Opaque"
}

## Create resource group
resource "azurerm_resource_group" "res-114" {
  location = var.config.region
  name     = var.config.resource_grp_name

}



