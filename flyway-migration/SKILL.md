---
name: flyway-migration
description: >
  Generate Flyway database migration files from SQL content following team conventions.
  Use this skill whenever the user wants to create a Flyway migration file, add/modify/drop
  a database table or column, write a db migration script, or mentions "flyway", "migration file",
  "db/migration", "V[date]__", or any variant of "create a migration for...". Even if the user
  just pastes SQL and says "make a migration from this", trigger this skill immediately.
---

# Flyway Migration File Generator

Generate properly named and formatted Flyway migration files under the team's standard path,
with idempotent SQL, using the correct versioning convention.

## Scripts

Two helper scripts handle date detection and sequence resolution. Load the one that matches the
current platform — **do not read both**.

| Platform | Script |
|---|---|
| Linux / macOS | `scripts/check_filename.sh` |
| Windows | `scripts/check_filename.ps1` |

Read the relevant script before executing it so you understand its arguments and output format.

---

## Migration Directory

```
yudao-module-system/yudao-module-system-server/src/main/resources/db/migration
```

All migration files live here. This is the **single source of truth**.

---

## File Naming Convention

```
V{YYYYMMDD}_{SEQ}__{description}.sql
```

| Part | Rule |
|---|---|
| `V` | Uppercase, always `V` (versioned script) |
| `{YYYYMMDD}` | Today's date, e.g. `20260508` |
| `_{SEQ}` | 3-digit zero-padded sequence per day: `_001`, `_002`, … |
| `__` | **Double** underscore separator — single underscore causes a Flyway parse error |
| `{description}` | Short snake_case summary of what the migration does |
| `.sql` | Lowercase `.sql` extension |

**Example:** `V20260508_001__add_order_relation_table.sql`

---

## Step-by-Step Workflow

### Step 1 — Detect the platform and read the matching script

```bash
uname -s 2>/dev/null || echo "Windows"
```

- Output contains `Linux` or `Darwin` → read and run **`scripts/check_filename.sh`**
- Command fails or output is `Windows` → read and run **`scripts/check_filename.ps1`**

Read the script file now so you know its exact usage before proceeding.

### Step 2 — Derive the description from the SQL

Inspect the SQL content the user provided and produce a concise snake_case description:

| SQL action | Description pattern |
|---|---|
| `CREATE TABLE foo` | `add_foo_table` |
| `DROP TABLE foo` | `drop_foo_table` |
| `ALTER TABLE foo ADD COLUMN bar` | `add_bar_to_foo` |
| `ALTER TABLE foo DROP COLUMN bar` | `drop_bar_from_foo` |
| `ALTER TABLE foo MODIFY / RENAME` | `modify_foo_table` |
| Multiple tables | `add_foo_and_bar_tables` |
| Index only | `add_index_on_foo_bar` |

Keep descriptions short (2–5 words), lowercase, underscore-separated.
If the user provides their own description, use it verbatim (spaces → underscores, lowercase).

### Step 3 — Run the script to get the filename

**Linux / macOS:**
```bash
bash scripts/check_filename.sh \
  "yudao-module-system/yudao-module-system-server/src/main/resources/db/migration" \
  "add_order_relation_table"
# → V20260508_001__add_order_relation_table.sql
```

**Windows:**
```powershell
.\scripts\check_filename.ps1 `
  -MigrationDir "yudao-module-system\yudao-module-system-server\src\main\resources\db\migration" `
  -Description "add_order_relation_table"
# → V20260508_001__add_order_relation_table.sql
```

Capture the output — this is the exact filename to use.

### Step 4 — Make the SQL idempotent (REQUIRED)

**Every statement must produce the same final state regardless of how many times it runs.** This is non-negotiable. Migrations get re-applied after failed deployments, schema repairs, environment refreshes, and partial-failure recoveries. A migration that throws "column already exists" on the second run blocks the entire Flyway history and forces a manual repair.

`IF NOT EXISTS` on `ALTER TABLE` is **not** portable — it only works in MySQL 8.0.29+ / MariaDB. For ALTER and DML, use explicit `INFORMATION_SCHEMA` precondition checks driven by `PREPARE` / `EXECUTE` / `DEALLOCATE`. This works on every MySQL 5.7+ deployment and makes the intent obvious to reviewers.

| Operation | Idempotency pattern |
|---|---|
| `CREATE TABLE` | `CREATE TABLE IF NOT EXISTS` |
| `DROP TABLE` | `DROP TABLE IF EXISTS` |
| `ALTER TABLE ADD/DROP/MODIFY COLUMN` | `INFORMATION_SCHEMA.COLUMNS` check + dynamic DDL |
| `CREATE INDEX` / `DROP INDEX` | `INFORMATION_SCHEMA.STATISTICS` check + dynamic DDL |
| `ADD FOREIGN KEY` | `INFORMATION_SCHEMA.TABLE_CONSTRAINTS` check + dynamic DDL |
| `UPDATE` / `INSERT` (DML) | `WHERE` clause that makes a re-run a no-op |

#### Pattern: ADD COLUMN

Check `INFORMATION_SCHEMA.COLUMNS` first, then build the DDL conditionally. When the column already exists, execute a harmless `SELECT 1` instead:

```sql
SET @col_exists := (
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'orders'
      AND COLUMN_NAME = 'status_code'
);
SET @ddl := IF(
    @col_exists = 0,
    'ALTER TABLE `orders` ADD COLUMN `status_code` int NULL DEFAULT NULL COMMENT ''Aggregated status derived from status_events'' AFTER `total_amount`',
    'SELECT 1'
);
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
```

Notes on this pattern:
- Inside the single-quoted DDL string, escape literal single quotes by doubling them (`''` for `'`) — that's why the column comment above is wrapped in `''…''`.
- Always scope the check to `TABLE_SCHEMA = DATABASE()` so the migration is environment-agnostic.
- Repeat the full block for each column. Do **not** try to batch multiple columns into one prepared statement — the failure modes are hard to reason about.

#### Pattern: DROP COLUMN

Invert the condition — execute the `DROP` only when the column is present:

```sql
SET @col_exists := (
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'orders'
      AND COLUMN_NAME = 'legacy_flag'
);
SET @ddl := IF(
    @col_exists = 1,
    'ALTER TABLE `orders` DROP COLUMN `legacy_flag`',
    'SELECT 1'
);
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
```

#### Pattern: CREATE INDEX

Query `INFORMATION_SCHEMA.STATISTICS` by index name:

```sql
SET @idx_exists := (
    SELECT COUNT(*)
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'orders'
      AND INDEX_NAME = 'idx_status_code'
);
SET @ddl := IF(
    @idx_exists = 0,
    'CREATE INDEX `idx_status_code` ON `orders` (`status_code`)',
    'SELECT 1'
);
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
```

#### Pattern: UPDATE / INSERT (DML)

DML is idempotent when the `WHERE` clause excludes already-migrated rows. The canonical move is `WHERE <new_column> IS NULL` for a backfill — once a row is populated, it will not be touched again:

```sql
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

For `INSERT`, use `INSERT IGNORE` with a unique key, `INSERT ... ON DUPLICATE KEY UPDATE`, or `INSERT ... SELECT ... WHERE NOT EXISTS (...)`. Naked `INSERT` statements are never acceptable in a migration.

> If a statement genuinely cannot be made idempotent (rare — usually a data-fix one-shot), leave a comment explaining why and exactly what guard the operator must apply before re-running. Treat this as the last resort, not the default.

### Step 5 — Write the migration file

Path:
```
yudao-module-system/yudao-module-system-server/src/main/resources/db/migration/{FILENAME}
```

Always include this header at the top:

```sql
-- Migration: {FILENAME}
-- Created:   {YYYY-MM-DD}
-- Description: {human-readable one-liner}
```

Then the idempotent SQL body.

### Step 6 — Show the result to the user

Display the full file path and complete file content for review before confirming it is done.

---

## Checklist

- [ ] Platform detected; correct script read and used
- [ ] Date obtained from system (never hardcoded)
- [ ] Sequence scanned from existing files for today; baseline files ignored
- [ ] Description is concise, snake_case, matches the actual SQL operation
- [ ] `CREATE/DROP TABLE` uses `IF NOT EXISTS` / `IF EXISTS`
- [ ] Every `ALTER TABLE` (add/drop/modify column, add index, add FK) is wrapped in an `INFORMATION_SCHEMA` precondition check + `PREPARE`/`EXECUTE`/`DEALLOCATE`
- [ ] Every `UPDATE` / `INSERT` has a `WHERE` guard (or `INSERT IGNORE` / `ON DUPLICATE KEY UPDATE`) that makes re-running a no-op
- [ ] Single quotes inside dynamic DDL strings are escaped as `''`
- [ ] Schema scope on every check is `TABLE_SCHEMA = DATABASE()` (not a hardcoded schema name)
- [ ] Double underscore `__` used (not single)
- [ ] Header comment present in the file
- [ ] File written to the correct path and shown to user

---

## Examples

### Example 1 — CREATE TABLE

**Input SQL:**
```sql
CREATE TABLE order_relation (
  id       BIGINT PRIMARY KEY AUTO_INCREMENT,
  order_id BIGINT NOT NULL,
  user_id  BIGINT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

**Today:** `2026-05-08` · **Existing migrations today:** none

**Generated file:** `V20260508_001__add_order_relation_table.sql`

```sql
-- Migration:   V20260508_001__add_order_relation_table.sql
-- Created:     2026-05-08
-- Description: Add order_relation table to store order-user associations

CREATE TABLE IF NOT EXISTS `order_relation` (
  `id`         BIGINT   NOT NULL AUTO_INCREMENT,
  `order_id`   BIGINT   NOT NULL,
  `user_id`    BIGINT   NOT NULL,
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Order-user relation';
```

### Example 2 — ADD COLUMN + backfill (idempotent ALTER + guarded UPDATE)

**Input intent:** add a `status_code` column to `orders`, then backfill it from `status_events`.

**Generated file:** `V20260508_002__add_status_code_to_orders.sql`

```sql
-- Migration:   V20260508_002__add_status_code_to_orders.sql
-- Created:     2026-05-08
-- Description: Add status_code to orders and backfill from status_events

SET @col_exists := (
    SELECT COUNT(*)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'orders'
      AND COLUMN_NAME = 'status_code'
);
SET @ddl := IF(
    @col_exists = 0,
    'ALTER TABLE `orders` ADD COLUMN `status_code` int NULL DEFAULT NULL COMMENT ''Aggregated status derived from status_events'' AFTER `total_amount`',
    'SELECT 1'
);
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

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

Re-running this file is a no-op: the `ALTER` is skipped because the column now exists, and the `UPDATE` matches zero rows because every target row has already been backfilled.

---

## Edge Cases

| Scenario | Handling |
|---|---|
| Migration dir does not exist | Script creates it automatically (`mkdir -p` / `New-Item`) |
| Multiple related SQL statements | Combine into one migration file |
| Multiple unrelated SQL statements | One file per logical change; run the script once per file |
| Baseline file present (`V{DATE}__baseline.sql`) | Script ignores it — pattern requires `_NNN__` segment |
| Sequence rolls from `009` to `010` | Both scripts strip leading zeros before arithmetic — no octal issue |
| User supplies a custom description | Use verbatim, normalise to snake_case lowercase |