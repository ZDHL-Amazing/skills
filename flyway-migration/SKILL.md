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

### Step 4 — Make the SQL idempotent

**All SQL must be idempotent.** Every statement must be safe to re-run accidentally:

```sql
-- CREATE TABLE
CREATE TABLE IF NOT EXISTS `foo` ( ... );

-- ADD COLUMN
ALTER TABLE `foo` ADD COLUMN IF NOT EXISTS `bar` VARCHAR(255);

-- DROP TABLE
DROP TABLE IF EXISTS `foo`;

-- DROP COLUMN (MySQL / MariaDB)
ALTER TABLE `foo` DROP COLUMN IF EXISTS `bar`;

-- CREATE INDEX
CREATE INDEX IF NOT EXISTS `idx_foo_bar` ON `foo`(`bar`);
```

> For older MySQL that lacks `IF NOT EXISTS` on `ALTER`, note in a comment that the statement was
> verified safe and should only be run once.

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
- [ ] All SQL statements have `IF NOT EXISTS` / `IF EXISTS` guards
- [ ] Double underscore `__` used (not single)
- [ ] Header comment present in the file
- [ ] File written to the correct path and shown to user

---

## Example

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