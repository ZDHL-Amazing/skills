# flyway-migration

A skill for generating Flyway database migration files (MySQL 8.0) that follow the team's
conventions. It triggers whenever you ask to create a Flyway migration, add/modify/drop a table or
column, or turn pasted SQL into a migration script.

## What it does

- Names files to the team standard: `V{YYYYMMDD}_{SEQ}__{description}.sql` (uppercase `V`, double
  underscore, lowercase `.sql`), and **locates the single directory Flyway actually scans by
  searching** for the `yudao-module-system-server/…/db/migration` suffix — so it works in a monorepo
  where the backend is nested under a subfolder, not just a plain backend checkout.
- Enforces **idempotency** — `IF NOT EXISTS` / `INFORMATION_SCHEMA` guards, one check per column, and
  `WHERE NOT EXISTS` row checks — so a re-run after a failed deploy never throws "already exists".
- Keeps **DDL and DML in separate files**, because MySQL implicitly commits on DDL and a single
  transaction cannot protect both halves.
- Allocates the migration version through the **`flyway-sequence` MCP** (see below) instead of
  scanning the directory, so concurrent authors never collide on the same daily sequence number.

## Install Skill

```bash
npx skills add git@github.com:ZDHL-Amazing/skills.git --skill flyway-migration
```

## Companion MCP: `flyway-sequence` (required)

Version numbers are handed out by a centralized, atomic counter exposed over MCP. The skill calls:

- `next_sequence` — allocates the next version prefix for today (e.g. `V20260528_002__`). Called once
  per file to be created.
- `rollback_sequence` — decrements the counter by one, used only when you explicitly ask to remove a
  previously allocated version.

Without this MCP the skill cannot allocate a version, so install it before using the skill.

First sign in at `https://flyway.ynbr.one/clients` with a GitHub organization member
account and register the client application. Registration is per application; users authorize
with their own accounts. Use a native public client with PKCE.

### Claude Code

Register `http://localhost:8080/callback`, then run:

```bash
claude mcp add --transport http --client-id YOUR_CLIENT_ID --callback-port 8080 \
  flyway-sequence https://flyway.ynbr.one/api/mcp
```

In an interactive Claude Code session, run `/mcp`, select `flyway-sequence`, and choose
**Authenticate**. Complete GitHub login and consent in your browser.

### Codex

Register `http://127.0.0.1/callback` as a native loopback callback, then run:

```bash
codex mcp add flyway-sequence --url https://flyway.ynbr.one/api/mcp --oauth-client-id YOUR_CLIENT_ID
codex mcp login flyway-sequence --scopes openid,profile,email,offline_access,mcp:write
```

Codex connects directly over HTTP and manages OAuth credentials. Access tokens last 24 hours;
refresh tokens last 180 days. Clients can refresh without repeating browser login. If you need
to switch accounts, use the client's logout and login commands.

Use a client version supporting MCP `2026-07-28`.

## Verify

After installing and authorizing, confirm the server is connected:

```bash
claude mcp list
```

You should see `flyway-sequence` listed as connected. Then ask the skill to create a migration — it
will call `next_sequence` to obtain the version prefix and append your description.
