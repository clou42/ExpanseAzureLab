# Trigger-escalation chain — verification

End-to-end check that a deployed ExpanseAzureLab honors the trigger-escalation
contract:

1. The SSRF env-leak surface at `/services` still exposes the App Service
   IMDS `IDENTITY_ENDPOINT` and `IDENTITY_HEADER`.
2. `/api/proxy` SSRF can be used to make the webapp call its own IMDS and
   return a `https://database.windows.net/` token.
3. The webapp managed identity has the **restricted per-table grant model**:
   - No `db_datareader` / `db_datawriter` role memberships.
   - Explicit `GRANT SELECT, INSERT, UPDATE, DELETE` on each of the five
     gameplay tables: `dbo.ships`, `dbo.crew_manifest`,
     `dbo.espionage_credentials`, `dbo.protomolecule_incidents`,
     `dbo.fleet_heartbeat`.
   - `GRANT ALTER` on `dbo.fleet_heartbeat` — the realistic misconfig that
     opens the trigger path.
   - `GRANT VIEW DEFINITION` on `dbo.protomolecule_samples` so the loot
     table shows up in catalog enumeration *but* `SELECT` is denied.
4. Direct escalation (`ALTER ROLE db_owner ADD MEMBER`) is blocked.
5. Planting a DML trigger on `dbo.fleet_heartbeat` succeeds (because of #3).
6. When an admin-context login INSERTs into `dbo.fleet_heartbeat`, the
   trigger runs in *that* login's context and adds the webapp MI to
   `db_owner`.
7. The webapp MI can now SELECT from `dbo.protomolecule_samples`.

The script is self-contained Python with `pyodbc`. No `az` CLI is required.

## Requirements

- **Python 3.9+**
- **ODBC Driver 18 for SQL Server** locally
  (`brew install msodbcsql18 mssql-tools18` on macOS; the official Microsoft
  packages on Linux)
- Network egress from the IP that's whitelisted in your
  `terraform.tfvars` `client_ip` (the same IP that runs `terraform apply`).
  Both the webapp and the SQL server's firewalls deny anything else.

## Setup

```bash
cd verify/trigger_escalation/
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # then fill in WEBAPP_FQDN, SQL_FQDN, and (optionally) admin SP creds
```

The values come from a `terraform apply` with `verbose = true` in
`terraform.tfvars`:

| .env key             | terraform output                                |
|----------------------|--------------------------------------------------|
| `WEBAPP_FQDN`        | `tycho_terminal_webapp_fqdn`                    |
| `SQL_FQDN`           | `tycho_fqdn`                                    |
| `TENANT_ID`          | `tenant_id`                                     |
| `ADMIN_SP_CLIENT_ID` | `tycho_db_sa_sp_client_id`                      |
| `ADMIN_SP_SECRET`    | `tycho_db_sp_client_secret`                     |

## Run

### Fast path (with admin SP creds, ~10 seconds)

```bash
python verify_chain.py
```

The admin SP token is used to fire one INSERT into `dbo.fleet_heartbeat`,
which triggers the planted DML trigger under the admin's security context.
This substitutes for the Donnager scheduled task and gets you a deterministic
answer in seconds.

### Slow path (no admin creds, waits for the natural Donnager heartbeat)

```bash
python verify_chain.py --no-fire
# or just omit TENANT_ID/ADMIN_SP_CLIENT_ID/ADMIN_SP_SECRET from .env
```

After planting the trigger, polls `dbo.fleet_heartbeat` for a new row.
Times out after ~7 minutes. The next scheduled Donnager tick (≤
`var.config.heartbeat_interval_minutes`, default 5) fires the trigger.

### Read-only sanity check

```bash
python verify_chain.py --check-only
```

Verifies the permission shape and loot-table state without planting any
trigger. Safe to run repeatedly.

### Cleanup after a verification run

```bash
python verify_chain.py --cleanup
```

Drops `dbo.trg_heartbeat_pwn` and removes the webapp MI from `db_owner`.

## Example successful output (fast path)

```
[*] 1) Scrape /services for IMDS env vars
    IDENTITY_ENDPOINT = http://169.254.129.4:8081/msi/token
    IDENTITY_HEADER   = 91fa767e-55ca-48f4-b17b-aaf9a05b77e2
    [+] IDENTITY_ENDPOINT leaked
    [+] IDENTITY_HEADER leaked

[*] 2) SSRF /api/proxy -> IMDS for database.windows.net token
    JWT aud=https://database.windows.net/  appid=eb24a58f-...  tid=ed0c263b-...
    [+] token aud = database.windows.net

[*] 3) Connect to tycho-db with token (pyodbc + access-token attr)
    USER_NAME() = tycho-terminal-ej4i531si2w5heb1
    ORIGINAL_LOGIN() = eb24a58f-...@ed0c263b-...
    [+] connected as the webapp MI

[*] 4) Verify permission shape (per-table grants, no role memberships)
    roles: (only public)
    [+] NOT member of db_datareader
    [+] NOT member of db_datawriter
    [+] NOT member of db_owner (yet)
    22 object grants visible to this principal
    [+] all 22 expected grants present

[*] 5) Loot table dbo.protomolecule_samples: visible in catalog, SELECT blocked
    [+] protomolecule_samples visible in sys.tables (via VIEW DEFINITION)
    blocked: ('42000', "[42000] [Microsoft][ODBC Driver 18 ...] The SELECT permission was denied on the object 'protomolecule_samples'...")
    [+] SELECT on dbo.protomolecule_samples is permission denied

[*] 6) Direct ALTER ROLE blocked (no implicit role-altering rights)
    blocked: ('42000', "[42000] ... Cannot alter the role 'db_owner', because it does not exist or you do not have permission ...")
    [+] direct ALTER ROLE blocked

[*] 7) Plant DML trigger on dbo.fleet_heartbeat
    trigger created

[*] 8) Fire heartbeat as the Tycho admin SP (substitutes for the scheduled task)
    admin token appid=704d945b-... (expected 704d945b-...)
    [+] client_credentials returned the right SP
    admin session: USER_NAME=dbo  ORIGINAL_LOGIN=704d945b-...@ed0c263b-...  IS_MEMBER(db_owner)=1
    [+] admin SP authenticates as db_owner-equivalent (dbo)
    INSERT executed under admin context

[*] 9) Reconnect as webapp MI and verify escalation + loot
    roles AFTER: ['db_owner']
    [+] webapp MI is now in db_owner
    [+] loot now readable (5 rows)
    LOOT (5 rows):
      PROTO-001-EROS         | Phoebe Black Site - Vault 7            | BLACK - TYCHO COUNCIL        | Contained
      PROTO-002-VENUS        | Behemoth Cargo Bay 3                   | BLACK - OPA INNER CIRCLE     | Lost
      PROTO-003-GANYMEDE     | Tycho Station - Refinery Vault A       | BLACK - TYCHO COUNCIL        | Sealed
      PROTO-004-ILUS         | Rocinante Lab Module 2                 | BLACK - HOLDEN ONLY          | Active
      PROTO-005-MEDINA       | Medina Station - Inaros Vault          | BLACK - FREE NAVY            | Unknown

=== ALL CHECKS PASSED ===
```

Exit code is **0** on full success, **1** on any failed assertion, **2** on
missing configuration.

## Internals (what each step proves)

| Step | Proves                                                                                                                          |
|------|---------------------------------------------------------------------------------------------------------------------------------|
| 1    | Env-leak surface remains exploitable; `services.ejs` has not been removed.                                                      |
| 2    | `/api/proxy` is still a forward proxy that accepts arbitrary URL + headers, and the App Service IMDS responds to the relayed call. |
| 3    | The leaked JWT is in fact accepted by `tycho-db` and maps to the webapp MI's contained database user (not, say, fred).         |
| 4    | The "release" grant model is in place: no `db_datareader`/`db_datawriter`; per-table grants only; the foothold (`ALTER` on `fleet_heartbeat`) is present and is the *only* grant of its kind. |
| 5    | The loot tease is correctly configured: visible name, no data access pre-escalation.                                            |
| 6    | The webapp MI has no path to `db_owner` without going through the trigger; the model is closed.                                 |
| 7    | `ALTER` on a single table is sufficient to plant a DML trigger on it — exactly the misconfig being modeled.                     |
| 8    | The trigger executes under the *writer's* security context, not the planter's. When the admin (`fred`/`dbo`) writes a row, the trigger's `ALTER ROLE` succeeds.            |
| 9    | The escalation actually took effect: the webapp MI is now `db_owner`, and that role grants implicit access to all objects, including `dbo.protomolecule_samples`. |

## When to run this

- **After every fresh `terraform apply`** of the `sql-trigger-escalate` branch
  to confirm the deploy is sound.
- After any modification to `tfscripts/blob_resources/expanse_init.sql`
  or `tfscripts/trigger_escalation.tf` (catches regressions in the grant
  set or table shape).
- After any change to the `tycho-terminal` webapp source (especially
  `/services` or `/api/proxy`) — step 1 or step 2 will fail loudly if the
  SSRF surface has been removed or hardened.

## Cleanup vs. left-pwned

After a verification run the lab is intentionally left in the
post-escalation state (`dbo.trg_heartbeat_pwn` planted, webapp MI in
`db_owner`). This is useful when you want to inspect the result manually.
Run `python verify_chain.py --cleanup` to reset.
