# `verify/` — chain verifiers

Each subfolder here is an independent, end-to-end verifier for one of the
lab's attack chains. Two uses:

1. **Regression tests.** Run a chain's `verify_chain.py` after any change to
   the relevant Terraform / app code; failures point at exactly which step
   of the chain regressed.
2. **Solutions / lab readiness checks.** The same scripts work as worked
   examples for someone trying to confirm a chain is exploitable from
   scratch on a fresh deploy.

## Available chains

| Folder | What it verifies |
|---|---|
| [`ssrf/`](ssrf/) | `/services` env-var leak + `/api/proxy` forward proxy → SSRF the App Service IMDS for an MI token. Verifies tokens issue for `database.windows.net`, `vault.azure.net`, and `management.azure.com`, and that all three identify the same managed identity (the webapp's). Foundation chain — many others build on top. |
| [`trigger_escalation/`](trigger_escalation/) | SSRF on the tycho-terminal webapp → IMDS token for the webapp MI → DML trigger planted on `dbo.fleet_heartbeat` → Donnager heartbeat (or admin-SP substitute) fires it → webapp MI escalated to `db_owner` → reads the loot table `dbo.protomolecule_samples`. |

## Convention each chain folder follows

- `README.md` — what's being verified, prerequisites, how to run, expected
  output (annotated).
- `verify_chain.py` — single-file Python verifier. Takes config from
  environment variables or a local `.env` file (never committed).
- `requirements.txt` — Python deps for the verifier.
- `.env.example` — template; `cp .env.example .env` and fill in.
- `.gitignore` — keeps `.env` and `.venv/` local.

Exit-code semantics every verifier honors:

| Code | Meaning |
|------|---------|
| `0`  | All checks passed |
| `1`  | At least one assertion failed |
| `2`  | Missing required configuration |

This makes it trivial to wire any chain into CI later (`run-all` style)
without each script needing to know about the others.

## Adding a new chain

1. Create `verify/<chain_name>/` (snake_case, matches the corresponding
   `.tf` file or attack name in `attacks/`).
2. Drop in the five files above. Reuse the layout of
   `trigger_escalation/verify_chain.py` as a starting point.
3. Make the script self-contained — no shared helpers across chains, so
   each chain stays runnable and reviewable in isolation.
4. Add a row to the table above.
