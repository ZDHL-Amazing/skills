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

## Scripts

Two helper scripts handle date detection and sequence resolution. Load only the one for the current
platform — **do not read both**.

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

**All migration files live here, including changes for other business modules** (erp, logistics,
processing, entrust). Flyway only scans this one location — files placed under another module's
`resources/db/migration/` will silently never run.

---

## File Naming Convention

```
V{YYYYMMDD}_{SEQ}__{description}.sql
```

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

### Step 1 — Detect the platform and read the matching script

```bash
uname -s 2>/dev/null || echo "Windows"
```

- Output contains `Linux` or `Darwin` → read and run **`scripts/check_filename.sh`**
- Command fails or output is `Windows` → read and run **`scripts/check_filename.ps1`**

### Step 2 — Derive the description from the SQL

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
```

Capture the output — this is the exact filename to use.

### Step 4 — Make the SQL idempotent (REQUIRED)

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
    `id`          BIGINT      NOT NULL AUTO_INCREMENT COMMENT '主键',
    -- 业务列 ...
    `creator`     VARCHAR(64) DEFAULT ''  COMMENT '创建者',
    `create_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    `updater`     VARCHAR(64) DEFAULT ''  COMMENT '更新者',
    `update_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    `deleted`     BIT(1)      NOT NULL DEFAULT b'0' COMMENT '是否删除',
    `tenant_id`   BIGINT      NOT NULL DEFAULT 0 COMMENT '租户编号',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='<表注释>';
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

### Step 5 — DDL and DML must not share a file

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

### Step 6 — Write the migration file

Path:

```
yudao-module-system/yudao-module-system-server/src/main/resources/db/migration/{FILENAME}
```

Always include this header:

```sql
-- Migration:   {FILENAME}
-- Created:     {YYYY-MM-DD}
-- Description: {human-readable one-liner}
```

Then the idempotent SQL body.

### Step 7 — Show the result to the user

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

- [ ] Platform detected; correct script read and used
- [ ] Date from system (never hardcoded), sequence scanned from existing files
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
- [ ] Uppercase `V`, double underscore `__`, file in the system module's `db/migration` directory
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
    `id`          BIGINT      NOT NULL AUTO_INCREMENT COMMENT '主键',
    `order_id`    BIGINT      NOT NULL COMMENT '订单ID',
    `user_id`     BIGINT      NOT NULL COMMENT '用户ID',
    `creator`     VARCHAR(64) DEFAULT ''  COMMENT '创建者',
    `create_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    `updater`     VARCHAR(64) DEFAULT ''  COMMENT '更新者',
    `update_time` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    `deleted`     BIT(1)      NOT NULL DEFAULT b'0' COMMENT '是否删除',
    `tenant_id`   BIGINT      NOT NULL DEFAULT 0 COMMENT '租户编号',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单与用户关系表';
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
| Migration dir does not exist | Script creates it automatically (`mkdir -p` / `New-Item`) |
| Multiple related DDL statements | Combine into one DDL file |
| Mixed DDL + DML intent | Split — one DDL file, one DML file (see Step 5) |
| Multiple unrelated changes | One file per logical change; run the script once per file |
| Baseline file (`V{DATE}__baseline.sql`) | Script ignores it — pattern requires `_NNN__` segment |
| Sequence rolls `009` → `010` | Scripts strip leading zeros before arithmetic — no octal issue |
| Failed migration blocks startup | See "Recovering from a failed migration" above |
| User supplies a custom description | Use verbatim, normalised to snake_case lowercase |
