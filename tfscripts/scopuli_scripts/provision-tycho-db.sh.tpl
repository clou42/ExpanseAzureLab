#!/bin/bash
# Provision tycho-db from the Scopuli VM.
#
# This script is rendered by templatefile() and base64-encoded into the
# scopuli_sql_provision Custom Script extension (see main.tf). It installs
# sqlcmd, seeds the database, creates the managed-identity DB users, and
# applies the per-deploy grants and planted loot.
#
# expanse_init.sql is passed in as base64 (expanse_init_b64) and decoded
# locally rather than downloaded from the public Pallas blob: that file
# documents the attack chains and must NOT be retrievable by players.
set -e

export DEBIAN_FRONTEND="noninteractive"
apt-get update
apt-get install -y wget curl apt-transport-https gnupg jq
curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
curl https://packages.microsoft.com/config/ubuntu/20.04/prod.list > /etc/apt/sources.list.d/msprod.list
apt-get update
apt-get install sqlcmd

# Seed schema + data from the inlined init script (no public blob).
echo "${expanse_init_b64}" | base64 -d > /tmp/expanse_init.sql

# 1) Bootstrap: give the Scopuli provisioner MI db_owner (admin SP auth).
echo "CREATE USER [${scopuli_provisioner_name}] FROM EXTERNAL PROVIDER; ALTER ROLE db_owner ADD MEMBER [${scopuli_provisioner_name}];" > /tmp/grant_mi.sql
sqlcmd -S tcp:${sql_fqdn} -d ${db_name} --authentication-method ActiveDirectoryServicePrincipal -U ${tycho_sa_client_id} -P ${tycho_sa_secret} -i /tmp/grant_mi.sql

# Switch to the provisioner MI token for the remaining steps.
curl -H "Metadata:true" "http://169.254.169.254/metadata/identity/oauth2/token?resource=https://database.windows.net/&api-version=2018-02-01" | jq -r .access_token > access.tkn

# 2) Run the schema/data seed.
sqlcmd -S tcp:${sql_fqdn} -d ${db_name} --authentication-method ActiveDirectoryManagedIdentity -I -i /tmp/expanse_init.sql -P access.tkn

# 3) Create the tycho-terminal webapp MI user with its per-table grants.
echo "CREATE USER [${webapp_name}] FROM EXTERNAL PROVIDER; GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.ships TO [${webapp_name}]; GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.crew_manifest TO [${webapp_name}]; GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.espionage_credentials TO [${webapp_name}]; GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.protomolecule_incidents TO [${webapp_name}]; GRANT VIEW DEFINITION ON OBJECT::dbo.protomolecule_samples TO [${webapp_name}];" > /tmp/grant_tycho-terminal-mi.sql
sqlcmd -S tcp:${sql_fqdn} -d ${db_name} --authentication-method ActiveDirectoryManagedIdentity -I -i /tmp/grant_tycho-terminal-mi.sql -P access.tkn

# 4) Insert Chrisjen's SP credentials (loot in dbo.espionage_credentials).
echo "${chrisjen_sql_b64}" | base64 -d > /tmp/insert-SG-credentials.sql
sqlcmd -S tcp:${sql_fqdn} -d ${db_name} --authentication-method ActiveDirectoryManagedIdentity -I -i /tmp/insert-SG-credentials.sql -P access.tkn

# 5) Patch the maintenance_jobs breadcrumb with the real Ceres backups bucket.
echo "${maintenance_jobs_sql_b64}" | base64 -d > /tmp/update-maint-jobs.sql
sqlcmd -S tcp:${sql_fqdn} -d ${db_name} --authentication-method ActiveDirectoryManagedIdentity -I -i /tmp/update-maint-jobs.sql -P access.tkn
