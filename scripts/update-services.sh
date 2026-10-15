#!/bin/sh
# Regenerates NetScanner/Resources/services.tsv (PORT<TAB>name) from the TCP entries in /etc/services.
set -eu
cd "$(dirname "$0")/.."
awk '!/^#/ && $2 ~ /\/tcp$/ { split($2, p, "/"); if (!(p[1] in seen)) { seen[p[1]] = 1; print p[1] "\t" $1 } }' /etc/services \
    | sort -n > NetScanner/Resources/services.tsv
echo "$(wc -l < NetScanner/Resources/services.tsv) services -> NetScanner/Resources/services.tsv"
