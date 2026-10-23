---
name: flyway-migration
description: >
  Generate Flyway database migration files (MySQL 8) following team conventions.
  Use this skill whenever the user wants to create a Flyway migration, add/modify/drop
  a database table or column, write a DB migration script, or mentions "flyway", "migration file",
  "db/migration", "V[date]__", or pastes SQL and says "make a migration from this".
  Enforces strict idempotency, MySQL 8.0-compatible syntax, and DDL/DML separation.
---

# Flyway Migration File Generator

Generate properly named, idempotent, MySQL 8.0-compatible Flyway migration files under the team's
standard path. Strong constraints below come from real production incidents — follow them exactly.

## Version Allocation (flyway-sequence MCP)

Migration versions are allocated **centrally and atomically** by the `flyway-sequence` MCP server —
never by scanning the directory or computing a sequence number by hand. Two classes of bug motivated
this: two people (or two agents) picking the same `_00N` on the same day, and an agent miscounting
after a partially-merged branch left a gap. A shared counter removes both.

| Tool | What it does | When to call it |
|---|---|---|
| `next_sequence` | Allocates the next version prefix for today | Exactly **once per file you are about to create** |
| `rollback_sequence` | Decrements today's counter by 1 | **Only** when the user explicitly asks to delete / retract / roll back / remove a version |

### `next_sequence`

Returns the complete version prefix — date, sequence number, and the trailing double underscore —
already assembled:

```json
{ "success": true, "sequence": "V20260528_002__", "message": null }
```

Build the filename by appending the description and `.sql` directly to `sequence`. The prefix
**already ends in `__`**, so do not add another underscore:

```
sequence + description + ".sql"
"V20260528_002__" + "add_new_user_table" + ".sql"
→ V20260528_002__add_new_user_table.sql
```

Derive the header `Created:` date from the prefix as well (`V20260528_…` → `2026-05-28`) so the date
and the version can never disagree.

If the response has `"success": false` or comes back as an error, **stop and report it** — do not
invent or hand-calculate a sequence as a workaround. A fabricated number collides with the shared
counter and produces duplicate versions.

### `rollback_sequence`

This decrements the shared counter by one, so each call must correspond to exactly one unwanted
allocation. Call it **only** on an explicit user instruction to remove or revert a version — e.g.
"delete that migration", "retract the previous version", "roll back the sequence".

Never call it on your own initiative: not after a failed file write, not after a validation error,
not when abandoning a draft, not "just to be safe". An automatic rollback after a transient hiccup
double-frees the number, and the next `next_sequence` then hands out a duplicate. If you allocated a
sequence and writing the file failed, retry the write with the **same** sequence rather than rolling
back.

---

## Locating the Migration Directory

Flyway scans exactly one directory. Across this team's repos it always ends in the suffix:

```
yudao-module-system-server/src/main/resources/db/migration
```

**All migration files live here, including changes for other business modules** (erp, logistics,
processing, entrust). Flyway only scans this one location — files placed under another module's
`resources/db/migration/` silently never run.

**Discover this directory by searching — never assume it sits at a fixed relative path.** In a plain
backend checkout it is `yudao-module-system/yudao-module-system-server/src/main/resources/db/migration`
under the repo root, but in a monorepo the backend is nested under some subfolder (alongside the
front-end), so a hardcoded path resolves to the wrong place — or, worse, silently creates an orphaned
`db/migration` tree that Flyway never scans and whose migrations never run. That failure is invisible
until a deploy is missing its schema change, which is exactly why we search instead of assuming.

The other business modules each keep their own `resources/db/migration/` folder that Flyway ignores.
The `yudao-module-system-server` portion of the suffix is what tells the real directory apart from
those decoys — match on the full suffix, not on a bare `db/migration`.

### How to find it (cross-platform)

Run the search from the repository root (or wherever the user is working). These approaches behave
identically on Windows, Linux, and macOS.

1. **Glob tool (primary).** Claude Code's built-in Glob tool needs no external binary and works the
   same on every OS. Match the migration files and take their parent directory:

   ```
   **/yudao-module-system-server/src/main/resources/db/migration/V*.sql
   ```

   The `V*.sql` filter confirms you've found the *active* Flyway directory — the one already holding
   real migrations — rather than an empty look-alike. The directory you want is the parent of any
   match.

2. **`rg` fallback (for agents without the Glob tool).** ripgrep ships for all three OSes; `rg --files`
   lists files while honoring `.gitignore`:

   ```bash
   rg --files -g '**/yudao-module-system-server/src/main/resources/db/migration/V*.sql'
   ```

   Take the parent directory of any result.

3. **Last-resort OS commands** (only if neither of the above is available):
   - Linux / macOS: `find . -type d -path '*/yudao-module-system-server/src/main/resources/db/migration'`
   - Windows PowerShell: `Get-ChildItem -Recurse -Directory | Where-Object { $_.FullName -like '*yudao-module-system-server\src\main\resources\db\migration' }`

**Use the path exactly as the tool returns it**, including its separators (`/` vs `\`). Don't rebuild
it by concatenating string fragments — that's how separator bugs and orphaned directories creep in on
Windows.

### Resolving the result

| Matches | What to do |
|---|---|
| Exactly one | Use that directory. This is the normal case. |
| More than one | Unusual — typically a nested git worktree or a vendored copy. Auto-pick the **shallowest** path (fewest separators — almost always the primary checkout), proceed, and tell the user which one you chose and what the alternatives were, so they can redirect you if the guess is wrong. |
| Zero | The backend module isn't in the current tree, or it lives somewhere unexpected. **Don't fabricate a path and write into it** — that recreates the original unsafe behavior. Warn the user, show where you searched, and ask them to point you at the `db/migration` directory before you write anything. |

Discover the path once and reuse it for Step 5 — there's no need to search again per file.

---

## File Naming Convention

```
V{YYYYMMDD}_{SEQ}__{description}.sql
```

`next_sequence` produces the `V{YYYYMMDD}_{SEQ}__` portion for you; you only supply
`{description}.sql`. The table below explains each part so you can sanity-check the final name.

| Part | Rule |
|---|---|
| `V` | **Uppercase** — lowercase `v` is silently ignored (no error, no execution) |
| `{YYYYMMDD}` | Today's date, e.g. `20260508` |
| `_{SEQ}` | 3-digit zero-padded sequence per day: `_001`, `_002`, … |
| `__` | **Double** underscore — single underscore is parsed as part of the version and errors |
| `{description}` | Short snake_case summary |
| `.sql` | Lowercase `.sql` extension |

**Example:** `V20260508_001__add_order_relation_table.sql`

---

## Step-by-Step Workflow

### Step 1 — Derive the description from the SQL

| SQL action | Description pattern |
|---|---|
| `CREATE TABLE foo` | `add_foo_table` |
| `DROP TABLE foo` | `drop_foo_table` |
| `ALTER TABLE foo ADD COLUMN bar` | `add_bar_to_foo` |
| `ALTER TABLE foo DROP COLUMN bar` | `drop_bar_from_foo` |
| `ALTER TABLE foo MODIFY / RENAME` | `modify_foo_table` |
| Multiple tables | `add_foo_and_bar_tables` |
| Index only | `add_index_on_foo_bar` |
| DML backfill | `backfill_<col>_in_<table>` |

Keep descriptions short (2–5 words), lowercase, underscore-separated. If the user supplies their
own description, use it verbatim (spaces → underscores, lowercase).

### Step 2 — Make the SQL idempotent (REQUIRED)

**Every statement must produce the same final state regardless of how many times it runs.** This is
non-negotiable. Re-runs happen after failed deployments, partial-failure recoveries, `flyway repair`,
and shared dev databases where someone already applied half the change manually. A migration that
throws "column already exists" on the second run writes a `success=0` row that blocks Flyway
validate and prevents the service from starting.

#### ❌ Banned syntax — MySQL 8.0 will error or silently misbehave

```sql
-- ❌ MariaDB-only extension; MySQL 8.0 raises a syntax error
ALTER TABLE t ADD COLUMN IF NOT EXISTS col INT;
ALTER TABLE t DROP COLUMN IF EXISTS col;

-- ❌ Multi-column ALTER — any one column already existing fails the whole statement
ALTER TABLE `erp_contract_name`
    ADD COLUMN `party_a_is_customer` TINYINT(1) NOT NULL DEFAULT 0 AFTER `party_b_id`,
    ADD COLUMN `is_cross_tenant`     TINYINT(1) NOT NULL DEFAULT 0 AFTER `party_a_is_customer`;
```

The second form burned us in `V20260519_002` — one column was hand-added on a dev DB, the
migration failed mid-way, wrote `success=0`, and every subsequent boot was rejected by Flyway
validate until someone deleted the row by hand. Always issue **one `INFORMATION_SCHEMA` check per
column**, never batch.

#### Idempotency by operation

| Operation | Pattern |
|---|---|
| `CREATE TABLE` | `CREATE TABLE IF NOT EXISTS` (natively idempotent) |
| `DROP TABLE` | `DROP TABLE IF EXISTS` |
| `CREATE VIEW` | `CREATE OR REPLACE VIEW` (natively idempotent) |
| `ALTER TABLE ADD/DROP/MODIFY COLUMN` | `INFORMATION_SCHEMA.COLUMNS` check + `PREPARE`/`EXECUTE` |
| `CREATE INDEX` / `DROP INDEX` | `INFORMATION_SCHEMA.STATISTICS` check + `PREPARE`/`EXECUTE` |
| `ADD FOREIGN KEY` | `INFORMATION_SCHEMA.TABLE_CONSTRAINTS` check + `PREPARE`/`EXECUTE` |
| `UPDATE` (backfill) | `WHERE <col> IS NULL` or `WHERE <col> = <old_value>` |
| `INSERT` | `INSERT ... SELECT ... WHERE NOT EXISTS (<target row check>)` |

#### Pattern: ADD COLUMN (one block per column)

```sql
SET @col_exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'orders'
      AND COLUMN_NAME  = 'status_code'
);
SET @ddl := IF(
    @col_exists = 0,
    'ALTER TABLE `orders` ADD COLUMN `status_code` INT NULL DEFAULT NULL COMMENT ''Aggregated status'' AFTER `total_amount`',
    'SELECT 1'
);
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
```

- Always scope the check with `TABLE_SCHEMA = DATABASE()` — never hardcode a schema name.
- Inside the single-quoted DDL string, escape literal single quotes by doubling them (`''…''`).
- For multi-column changes, **repeat the entire SET / IF / PREPARE block per column** — do not
  batch into one prepared statement.

#### Pattern: DROP COLUMN

Same shape, condition inverted: `IF(@col_exists = 1, '...DROP COLUMN...', 'SELECT 1')`.

#### Pattern: CREATE INDEX

```sql
SET @idx_exists := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'orders'
      AND INDEX_NAME   = 'idx_orders_status_code'
);
SET @ddl := IF(
    @idx_exists = 0,
    'ALTER TABLE `orders` ADD INDEX `idx_orders_status_code` (`status_code`)',
    'SELECT 1'
);
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
```

#### Pattern: CREATE TABLE (BaseDO 7 standard columns)

`CREATE TABLE IF NOT EXISTS` is natively idempotent. Every new business table must retain the
seven BaseDO columns:

```sql
CREATE TABLE IF NOT EXISTS `<table>` (
    `id`          BIGINT      NOT NULL AUTO_INCREMENT COMMENT 'Primary key',
    -- Business columns ...
    `creator`     VARCHAR(64) DEFAULT ''  COMMENT 'Created by',
    `create_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Creation time',
    `updater`     VARCHAR(64) DEFAULT ''  COMMENT 'Updated by',
    `update_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Update time',
    `deleted`     BIT(1)      NOT NULL DEFAULT b'0' COMMENT 'Deletion flag',
    `tenant_id`   BIGINT      NOT NULL DEFAULT 0 COMMENT 'Tenant ID',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='<table comment>';
```

#### Pattern: UPDATE backfill

A backfill is idempotent when the `WHERE` clause excludes already-migrated rows. Canonical forms:

- `WHERE <new_col> IS NULL` — column exists but value is unset.
- `WHERE <col> = '<old_value>'` — state-value migration.

Re-running matches zero rows → no-op. Example:

```sql
UPDATE `orders` o
SET `status_code` = ( /* derived value */ )
WHERE o.`status_code` IS NULL;
```

#### Pattern: INSERT — `WHERE NOT EXISTS` must target the row itself

INSERT idempotency requires checking that the **target row** is absent, not that some parent row
exists. This was the `V20260522_019` incident:

```sql
-- ❌ Wrong: only verifies the parent row, target row is re-inserted on every run
INSERT INTO `system_tenant_type_dept` (...)
SELECT ... WHERE EXISTS (SELECT 1 FROM `system_tenant_type` WHERE id = 1);

-- ✅ Right: verifies the exact target row by its unique key
INSERT INTO `system_tenant_type_dept` (`type_id`, `dept_code`, ...)
SELECT 1, 'PURCHASE', ...
WHERE NOT EXISTS (
    SELECT 1 FROM `system_tenant_type_dept`
    WHERE `type_id` = 1 AND `dept_code` = 'PURCHASE' AND `deleted` = b'0'
);
```

Naked `INSERT` statements are never acceptable in a migration.

### Step 3 — DDL and DML must not share a file

**One file is either DDL (`CREATE` / `ALTER` / `DROP`) or DML (`INSERT` / `UPDATE` / `DELETE`) —
never both.** MySQL implicitly commits when a DDL statement runs, so a transaction cannot protect
both halves. If the DDL commits and the DML then errors, you cannot roll back; the database is left
half-migrated and the Flyway row is `success=0`.

We have prior near-misses (`V20260521_005/006/008`, `V20260522_012`) where mixed files only escaped
incident because each DML happened to be idempotent via a `WHERE … IS NULL` guard. **That was luck,
not policy.** Split the change:

```
V20260521_005__add_dispatch_status_columns.sql   ← pure DDL
V20260521_006__backfill_dispatch_status.sql      ← pure DML
```

The DDL file runs first to add the column; the DML file runs after to backfill. Each file is
independently idempotent.

### Step 4 — Allocate a version for each file via `next_sequence`

By now you know how many files you are creating — one for a pure DDL or pure DML change, two if you
split. Call `next_sequence` **once for each of those files**, right before you write it:

1. Call `next_sequence`.
2. Read `sequence` from the response (e.g. `V20260528_002__`).
3. Filename = `sequence` + description + `.sql` → `V20260528_002__add_status_code_to_orders.sql`.

For a DDL + DML split, call `next_sequence` twice. The two consecutive numbers it returns keep the
DDL file ordered ahead of the DML file (e.g. `_002` for the DDL, `_003` for the DML), which is exactly
the run order you want.

Don't pre-allocate sequences you might not use, and never reuse or hand-edit a returned number — the
counter is shared with everyone working today, so a guessed number will eventually collide with a
real one.

### Step 5 — Write the migration file

Write into the directory you discovered in "Locating the Migration Directory" — not a hardcoded
relative path:

```
{MIGRATION_DIR}/{FILENAME}
```

where `{MIGRATION_DIR}` is the located path ending in
`yudao-module-system-server/src/main/resources/db/migration`.

Always include this header:

```sql
-- Migration:   {FILENAME}
-- Created:     {YYYY-MM-DD}
-- Description: {human-readable one-liner}
```

Then the idempotent SQL body.

### Step 6 — Show the result to the user

Display the full file path and complete file content for review before confirming the task is done.
If you split DDL/DML into two files, show both.

---

## Already-shipped files are frozen

A file that has merged to `main` and recorded `success=1` in `flyway_schema_history` **must never
be edited**. Flyway validates the file's checksum against the recorded one — any change rejects
the next startup. For a new requirement, open a new version file.

---

## Recovering from a failed migration

When a migration errors mid-run, Flyway records `success=0` and refuses to start on the next boot.
Fix:

```sql
-- 1. Delete the failed row
DELETE FROM flyway_schema_history WHERE version = '<version>' AND success = 0;
```

Then **make the migration script itself idempotent** (per the patterns above) and restart. Flyway
will retry the migration cleanly.

---

## Checklist

- [ ] Version allocated via `next_sequence` — one call per file, never hand-computed or reused
- [ ] Filename = returned `sequence` + description + `.sql` (no extra underscore — prefix already ends in `__`)
- [ ] `Created:` date taken from the returned prefix, not hardcoded
- [ ] `rollback_sequence` called only on an explicit user request to remove a version (never auto)
- [ ] Description is concise, snake_case, matches the SQL operation
- [ ] No `ALTER TABLE ... IF NOT EXISTS` / `IF EXISTS` (MariaDB-only syntax)
- [ ] No multi-column batched `ALTER` — one `INFORMATION_SCHEMA` block per column
- [ ] `CREATE/DROP TABLE` uses `IF NOT EXISTS` / `IF EXISTS`; `CREATE VIEW` uses `OR REPLACE`
- [ ] New tables include the 7 BaseDO standard columns
- [ ] Every `ALTER` (column/index/FK) wrapped in `INFORMATION_SCHEMA` check + `PREPARE`/`EXECUTE`/`DEALLOCATE`
- [ ] Single quotes inside dynamic DDL strings escaped as `''`
- [ ] Every `UPDATE` has `WHERE <col> IS NULL` or `WHERE <col> = <old_value>`
- [ ] Every `INSERT` has `WHERE NOT EXISTS (<target row check>)` — not a parent-row check
- [ ] **No DDL and DML in the same file** — split into two
- [ ] Schema scope is `TABLE_SCHEMA = DATABASE()` (never a hardcoded schema name)
- [ ] Migration directory **located by searching** for the `yudao-module-system-server/…/db/migration` suffix (not a hardcoded path); user warned if multiple/zero matches
- [ ] Uppercase `V`, double underscore `__`, file written into that discovered directory
- [ ] Header comment present
- [ ] File written and shown to user

---

## Examples

### Example 1 — CREATE TABLE (with BaseDO)

**Input intent:** create an `order_relation` table.

**Generated file:** `V20260508_001__add_order_relation_table.sql`

```sql
-- Migration:   V20260508_001__add_order_relation_table.sql
-- Created:     2026-05-08
-- Description: Add order_relation table to store order-user associations

CREATE TABLE IF NOT EXISTS `order_relation` (
    `id`          BIGINT      NOT NULL AUTO_INCREMENT COMMENT 'Primary key',
    `order_id`    BIGINT      NOT NULL COMMENT 'Order ID',
    `user_id`     BIGINT      NOT NULL COMMENT 'User ID',
    `creator`     VARCHAR(64) DEFAULT ''  COMMENT 'Created by',
    `create_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Creation time',
    `updater`     VARCHAR(64) DEFAULT ''  COMMENT 'Updated by',
    `update_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Update time',
    `deleted`     BIT(1)      NOT NULL DEFAULT b'0' COMMENT 'Deletion flag',
    `tenant_id`   BIGINT      NOT NULL DEFAULT 0 COMMENT 'Tenant ID',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Order-user associations';
```

### Example 2 — ADD COLUMN + backfill (split into two files)

**Input intent:** add `status_code` to `orders`, then backfill it from `status_events`.

Because DDL and DML cannot share a file, this is two migrations.

**File A — DDL:** `V20260508_002__add_status_code_to_orders.sql`

```sql
-- Migration:   V20260508_002__add_status_code_to_orders.sql
-- Created:     2026-05-08
-- Description: Add status_code column to orders

SET @col_exists := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'orders'
      AND COLUMN_NAME  = 'status_code'
);
SET @ddl := IF(
    @col_exists = 0,
    'ALTER TABLE `orders` ADD COLUMN `status_code` INT NULL DEFAULT NULL COMMENT ''Aggregated status derived from status_events'' AFTER `total_amount`',
    'SELECT 1'
);
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
```

**File B — DML:** `V20260508_003__backfill_status_code_in_orders.sql`

```sql
-- Migration:   V20260508_003__backfill_status_code_in_orders.sql
-- Created:     2026-05-08
-- Description: Backfill orders.status_code from latest status_events row

UPDATE `orders` o
SET `status_code` = (
    SELECT CASE
        WHEN e.`raw_status` IN ('NEW', 'QUEUED')      THEN 1
        WHEN e.`raw_status` IN ('PICKING', 'PACKING') THEN 2
        WHEN e.`raw_status` = 'SHIPPED'               THEN 3
        WHEN e.`raw_status` = 'DELIVERED'             THEN 4
        WHEN e.`raw_status` = 'CANCELLED'             THEN 9
        ELSE NULL
    END
    FROM `status_events` e
    WHERE e.`is_deleted` = 0
      AND e.`source_type` = 'ORDER'
      AND e.`source_id`   = o.`id`
    ORDER BY e.`updated_at` DESC, e.`event_id` DESC
    LIMIT 1
)
WHERE o.`status_code` IS NULL;
```

Re-running either file is a no-op: the DDL is skipped when the column exists; the UPDATE matches
zero rows when every target has been backfilled.

---

## Edge Cases

| Scenario | Handling |
|---|---|
| Search finds no migration directory | Don't fabricate a path — warn the user, show where you searched, and ask them to point you at the directory (see "Locating the Migration Directory") |
| Search finds multiple migration directories | Auto-pick the shallowest path and tell the user which you chose and what the alternatives were (see "Locating the Migration Directory") |
| Monorepo (front-end + back-end in one tree) | The backend is nested under a subfolder, so the migration dir is *not* at the repo root — the search handles this; never assume the fixed relative path |
| Multiple related DDL statements | Combine into one DDL file (one `next_sequence` call) |
| Mixed DDL + DML intent | Split — one DDL file, one DML file (see Step 3); call `next_sequence` once per file |
| Multiple unrelated changes | One file per logical change; call `next_sequence` once per file |
| `next_sequence` returns `success: false` / error | Stop and report it — never fall back to a hand-computed number |
| User accidentally allocated a sequence and asks to undo it | Call `rollback_sequence` once per version to remove (only on explicit request) |
| Failed file write after allocating | Retry the write with the **same** sequence; do not `rollback_sequence` |
| Failed migration blocks startup | See "Recovering from a failed migration" above |
| User supplies a custom description | Use verbatim, normalised to snake_case lowercase |
