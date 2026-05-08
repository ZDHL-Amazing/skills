# next_filename.ps1
# Usage: .\next_filename.ps1 -MigrationDir <path> -Description <description>
# Output: the full migration filename, e.g. V20260508_001__add_order_table.sql
#
# Compatible with: Windows PowerShell 5.1+, PowerShell 7+ (cross-platform)

param(
    [Parameter(Mandatory=$true)]
    [string]$MigrationDir,

    [Parameter(Mandatory=$true)]
    [string]$Description
)

# ── 1. Today's date ──────────────────────────────────────────────────────────
$Today = Get-Date -Format 'yyyyMMdd'

# ── 2. Ensure migration directory exists ─────────────────────────────────────
if (-not (Test-Path $MigrationDir)) {
    New-Item -ItemType Directory -Path $MigrationDir -Force | Out-Null
}

# ── 3. Find highest sequence number for today ────────────────────────────────
# Matches files like: V20260508_001__xxx.sql
$Pattern = "^V${Today}_(\d{3})__.*\.sql$"

$Existing = Get-ChildItem -Path $MigrationDir -Filter "V${Today}_*__*.sql" -File `
    | Where-Object { $_.Name -match $Pattern } `
    | ForEach-Object { [int]$Matches[1] } `
    | Sort-Object `
    | Select-Object -Last 1

# ── 4. Calculate next sequence ───────────────────────────────────────────────
if ($null -eq $Existing) {
    $NextNum = 1
} else {
    $NextNum = $Existing + 1
}

$NextSeq = $NextNum.ToString('000')

# ── 5. Output filename ───────────────────────────────────────────────────────
Write-Output "V${Today}_${NextSeq}__${Description}.sql"