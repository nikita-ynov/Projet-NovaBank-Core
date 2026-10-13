#!/bin/bash
set -euo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$RACINE/logs"

echo "== tests SQL (les ERROR sont normaux : ce sont les interdits qui sont refuses) =="
sudo -u postgres psql -X -d bankdb < "$RACINE/sql/08_tests.sql" 2>&1 | tee "$RACINE/logs/08_tests.log"

echo
echo "== test de concurrence =="
bash "$RACINE/tests/test_concurrence.sh" 2>&1 | tee "$RACINE/logs/test_concurrence.log"
