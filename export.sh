#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Export one yearly wiewarm CSV directly from PostgreSQL using psql.

Usage:
  ./export.sh [YEAR]

Behavior:
  - Defaults to the current UTC year if YEAR is omitted
  - Writes ./wiewarm-YEAR.csv
  - Uses standard libpq environment variables for connection details:
      PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
    or DATABASE_URL / PGSERVICE if you already use one

Example:
  PGHOST=db.example.org PGDATABASE=wiewarm PGUSER=postgres PGPASSWORD=secret \
    ./export.sh 2024
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

YEAR="${1:-$(date -u +%Y)}"

if [[ ! "$YEAR" =~ ^[0-9]{4}$ ]]; then
  echo "ERROR: year must be a 4-digit value, got: $YEAR" >&2
  exit 1
fi

FROM_DATE="${YEAR}-01-01"
TO_DATE="$((YEAR + 1))-01-01"
OUT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wiewarm-${YEAR}.csv"
TMP_FILE="${OUT_FILE}.tmp"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

if [[ -z "${PGDATABASE:-}" && -z "${DATABASE_URL:-}" && -z "${PGSERVICE:-}" ]]; then
  echo "ERROR: set PGDATABASE (or DATABASE_URL / PGSERVICE) plus the usual PostgreSQL connection env vars before running this script." >&2
  exit 1
fi

{
  printf 'datum;badid;bad;adresse1;adresse2;ort;plz;kanton;beckenid;becken;typ;temperatur\n'

  PSQL_ARGS=()
  if [[ -n "${DATABASE_URL:-}" ]]; then
    PSQL_ARGS+=("${DATABASE_URL}")
  fi

  psql "${PSQL_ARGS[@]}" -X -v ON_ERROR_STOP=1 \
    -v from_date="'${FROM_DATE}'" \
    -v to_date="'${TO_DATE}'" <<'SQL'
\pset footer off
\copy (
  select
    t.datum as "datum",
    b.id as "badid",
    b.name as "bad",
    b.adresse1 as "adresse1",
    b.adresse2 as "adresse2",
    b.ort as "ort",
    b.plz as "plz",
    b.kanton as "kanton",
    be.id as "beckenid",
    be.name as "becken",
    kt.bezeichnung as "typ",
    t.wert / 10.0 as "temperatur"
  from bad b
  join becken be on b.id = be.badid
  join temperatur t on be.id = t.beckenid
  left join katalog kt on be.typ = kt.itemid and kt.gruppe = 1
  where t.datum >= :from_date
    and t.datum < :to_date
  order by 1, 3
) to stdout with (format csv, header false, delimiter ';')
SQL
} > "$TMP_FILE"

mv "$TMP_FILE" "$OUT_FILE"

echo "Wrote $OUT_FILE"
