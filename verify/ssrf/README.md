# `verify/ssrf/` — tycho-terminal SSRF chain

Verifies that the tycho-terminal webapp still exposes both halves of the
SSRF chain, and that combining them yields a usable managed-identity
access token.

This is the **foundational** chain — many other chains
([`../trigger_escalation/`](../trigger_escalation/) included) start by
extracting an MI token via this route. Keeping a dedicated verifier here
catches regressions before they break every dependent chain.

## What the chain actually exploits

1. **`/services` env leak.** The "Diagnostics" panel dumps `process.env`
   into a tidy HTML table, including `IDENTITY_ENDPOINT` and
   `IDENTITY_HEADER` — the App Service IMDS authn pair. These point at a
   link-local address (`http://169.254.x.x:8081/msi/token`) that's
   unreachable from outside the App Service container.
2. **`/api/proxy` forward proxy.** Accepts `{url, headers}` JSON and
   makes the request from *inside* the container. Combine with #1 and
   the webapp will fetch its own IMDS endpoint for you, returning a
   bearer token for any Azure resource the MI can mint a token for.

## What this verifier asserts

| Step | Assertion |
|---|---|
| 1 | `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are present in `/services`, and `IDENTITY_ENDPOINT` is link-local (169.254.x.x) — confirming the env leak is the *only* path to it. |
| 2 | SSRF via `/api/proxy` returns a JWT for `https://database.windows.net/` with matching `aud`. |
| 2 | Same for `https://vault.azure.net`. |
| 2 | Same for `https://management.azure.com/`. |
| 3 | All three tokens share one `appid` and one `oid` — i.e. they all belong to the same managed identity (the webapp's). |
| 4 | The JWT `xms_mirid` claim points at a `Microsoft.Web/sites/*` resource matching `WEBAPP_FQDN` — confirms the SSRF lands on the right App Service. |

## Requirements

- Python 3.9+ (stdlib only — no `pip install` needed)
- Network egress from the IP whitelisted in your `terraform.tfvars`
  `client_ip`

## Setup

```bash
cd verify/ssrf/
cp .env.example .env   # then fill in WEBAPP_FQDN; TENANT_ID is optional
```

| .env key       | terraform output                |
|----------------|----------------------------------|
| `WEBAPP_FQDN`  | `tycho_terminal_webapp_fqdn`    |
| `TENANT_ID`    | `tenant_id` (optional, tightens assertions on `tid`) |

## Run

```bash
python verify_chain.py
```

Exit codes:

| Code | Meaning |
|------|---------|
| `0`  | All checks passed |
| `1`  | At least one assertion failed (env leak missing, proxy blocked, audience mismatch, etc.) |
| `2`  | Missing required configuration (`WEBAPP_FQDN`) |

## Example successful output

```
[*] 1) Scrape /services for IMDS env vars
    IDENTITY_ENDPOINT = http://169.254.129.4:8081/msi/token
    IDENTITY_HEADER   = 91fa767e-55ca-48f4-b17b-aaf9a05b77e2
    [+] IDENTITY_ENDPOINT leaked
    [+] IDENTITY_HEADER leaked
    [+] IDENTITY_ENDPOINT points to link-local (169.254.x.x) -- unreachable except via SSRF

[*] 2) SSRF /api/proxy -> IMDS for database.windows.net token
    aud=https://database.windows.net/  appid=eb24a58f-...  oid=...  tid=ed0c263b-...
    [+] JWT aud matches requested resource (https://database.windows.net/)

[*] 2) SSRF /api/proxy -> IMDS for vault.azure.net token
    aud=https://vault.azure.net  appid=eb24a58f-...  oid=...  tid=ed0c263b-...
    [+] JWT aud matches requested resource (https://vault.azure.net)

[*] 2) SSRF /api/proxy -> IMDS for management.azure.com token
    aud=https://management.azure.com/  appid=eb24a58f-...  oid=...  tid=ed0c263b-...
    [+] JWT aud matches requested resource (https://management.azure.com/)

[*] 3) All tokens originate from the same managed identity
    distinct appids: {'eb24a58f-064c-4f1d-a3c1-a2baf93b8862'}
    distinct oids:   {'...'}
    [+] all SSRF tokens share one appid
    [+] all SSRF tokens share one oid

[*] 4) JWT identifies the webapp managed identity
    xms_mirid = /subscriptions/.../resourceGroups/.../providers/Microsoft.Web/sites/tycho-terminal-...
    [+] xms_mirid points at a Microsoft.Web/sites/* resource (App Service MI)
    [+] xms_mirid resource name matches WEBAPP_FQDN

=== SSRF chain: PASS ===
```

## When to run

- **After every `terraform apply`** — confirms `/services` and `/api/proxy`
  still work and the App Service MI can mint tokens.
- After any change to the `tycho-terminal` webapp source (especially
  `routes/services.js` or `routes/proxy.js`) — catches accidental
  hardening that would close the SSRF.
- Before running [`../trigger_escalation/`](../trigger_escalation/) on a
  fresh deploy, to isolate "SSRF works" from "SQL chain works."

## What this *doesn't* check

- Whether the obtained tokens actually grant access to anything. The
  webapp MI may or may not have RBAC on Key Vault, the SQL DB, or ARM;
  that's a function of the lab's role assignments, not the SSRF surface
  itself. Downstream chains (e.g. `trigger_escalation`) verify those
  RBAC-dependent privileges separately.
