#!/bin/sh
# Regenerates NetScanner/Resources/oui.tsv (HEX_PREFIX<TAB>Vendor) from the IEEE MA-L registry.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -A "Mozilla/5.0 NetScanner" https://standards-oui.ieee.org/oui/oui.csv -o "$tmp"
python3 -I - "$tmp" NetScanner/Resources/oui.tsv <<'EOF'
import csv, sys
src, dst = sys.argv[1], sys.argv[2]
rows = {}
with open(src, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        prefix = row["Assignment"].strip().upper()
        name = " ".join(row["Organization Name"].split())
        if len(prefix) == 6 and name:
            rows[prefix] = name
with open(dst, "w", encoding="utf-8") as f:
    for prefix in sorted(rows):
        f.write(f"{prefix}\t{rows[prefix]}\n")
print(f"{len(rows)} vendors -> {dst}")
EOF
