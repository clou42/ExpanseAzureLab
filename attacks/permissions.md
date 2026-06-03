# Privileges & Role Reference (SPOILER)

> **Spoiler warning:** this file documents the intended privileges and access paths of the lab.
> It is deliberately kept out of the deployment `Readme.md`. Skip it if you want to solve the lab blind.

## User job titles

The `job_title` field in `users.csv` determines a user's permissions. Role bindings and custom roles are defined in `tfscripts/main.tf`.

**Crew**
- `Virtual Machine User Login` on the `Rocinante` VM.
- `Key Vault Administrator` on the `Ganymede` Key Vault.

**Pilot**
- The custom `VM_Rocinante_RunCommand_ExtensionsWrite` role on the `Rocinante` VM, which yields:
  ```
  "Microsoft.Compute/virtualMachines/runCommand/*",
  "Microsoft.Compute/virtualMachines/extensions/*",
  "Microsoft.Compute/virtualMachines/read"
  ```

**Captain**
- `Virtual Machine Contributor` on the `Rocinante` VM.

**Secretary General**
- `Cluster Admin` on the "Earthfleet" AKS cluster and `Microsoft.ContainerService/managedClusters/*` via the custom `aks_sg_admin` role.

## Service principals & managed identities

These are surfaced by the verbose output (`verbose = true`) for direct access.

- **Privileged SP (`Protomolecule`)** — `Contributor` on the resource group; an additional entry point. Outputs: `priv_sp_proto_client_id`, `priv_sp_proto_client_secret`, `tenant_id`.
- **Tycho DB admin SP** — administrator of the `Tycho` database. Outputs: `tycho_db_sa_sp_client_id`, `tycho_db_sp_client_secret`, `tenant_id`.
- **`Alex` and `Jim`** — code-execution privileges on the `Rocinante` VM, usable as a direct entry.
- **`KeysToTheScopuli` MI** — attached to the `Rocinante` VM; allows `RunCommand` / `Extensions/Write` on the `Scopuli` VM. Output: `KeysToTheScopuli_MI_principal_id`.
- **`JovianAccess` MI** — attached to the `Donnager` VM; can read the `Ganymede` Key Vault. The `Scopuli` VM identity can `RunCommand` on `Donnager`. Outputs: `Donnager_MI_principal_id`, `Donnager_admin_user`, `Donnager_public_IP` (RDP).
