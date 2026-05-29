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

### Claude Code

```bash
claude mcp add --transport http \
  flyway-sequence \
  https://flyway.ynbr.one/api/mcp
```

### Codex

Add to your Codex config (`~/.codex/config.toml`). Codex reaches the HTTP endpoint through the
`mcp-remote` bridge:

```toml
[mcp_servers.flyway-sequence]
command = "npx"
args = [
  "-y",
  "mcp-remote@latest",
  "https://flyway.ynbr.one/api/mcp",
]
```

## Authorization

The server uses OAuth — you log in through the browser once, and the client caches the token for
later runs. Adding the server (above) only registers it; you still need to authorize before the
tools work.

### Claude Code

After `claude mcp add …`, the server is registered but unauthenticated. Inside an interactive
Claude Code session:

1. Run the `/mcp` command.
2. Select `flyway-sequence` from the list.
3. Choose **Authenticate** — this opens your browser to the login page.
4. Complete the login. Claude Code stores the token and the server flips to **connected**.

If the token expires later, repeat `/mcp` → `flyway-sequence` → **Authenticate** to refresh it.

### Codex

`mcp-remote` drives the OAuth flow for you. The first time Codex starts the server, `mcp-remote`
opens a browser window to the login page (in a headless environment it prints a URL to open
manually). After you finish logging in, the token is cached under `~/.mcp-auth/` and reused on
subsequent runs — no per-session login needed.

To force a fresh login (e.g. the token went stale or you switched accounts), clear the cache:

```bash
rm -rf ~/.mcp-auth
```

The next Codex run will trigger the browser login again.

## Verify

After installing and authorizing, confirm the server is connected:

```bash
claude mcp list
```

You should see `flyway-sequence` listed as connected. Then ask the skill to create a migration — it
will call `next_sequence` to obtain the version prefix and append your description.
