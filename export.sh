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
  - Uses DATABASE_URL / PGSERVICE if set
  - Otherwise uses standard libpq environment variables
  - If present, also reads defaults from ../.env.sh and ../.secrets.sh
  - Defaults PGHOST to localhost

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/../.env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../.env.sh"
fi

if [[ -f "${SCRIPT_DIR}/../.secrets.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../.secrets.sh"
fi

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGDATABASE="${PGDATABASE:-${ENV_POSTGRES_DB:-}}"
export PGUSER="${PGUSER:-${SECRET_POSTGRES_USER:-}}"
export PGPASSWORD="${PGPASSWORD:-${SECRET_POSTGRES_PASSWORD:-}}"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

if [[ -z "${DATABASE_URL:-}" && -z "${PGSERVICE:-}" && -z "${PGDATABASE:-}" ]]; then
  echo "ERROR: no database configured. Set DATABASE_URL, PGSERVICE, PGDATABASE, or ENV_POSTGRES_DB." >&2
  exit 1
fi

if [[ -z "${DATABASE_URL:-}" && -z "${PGSERVICE:-}" && ( -z "${PGUSER:-}" || -z "${PGPASSWORD:-}" ) ]]; then
  echo "ERROR: missing PostgreSQL credentials. Set PGUSER/PGPASSWORD or SECRET_POSTGRES_USER/SECRET_POSTGRES_PASSWORD." >&2
  exit 1
fi

{
  printf 'datum;badid;bad;adresse1;adresse2;ort;plz;kanton;beckenid;becken;typ;temperatur\n'

  PSQL_ARGS=()
  if [[ -n "${DATABASE_URL:-}" ]]; then
    PSQL_ARGS+=("${DATABASE_URL}")
  fi

  psql "${PSQL_ARGS[@]}" -X -v ON_ERROR_STOP=1 <<SQL
COPY (
  select
    to_char(t.datum, 'YYYY-MM-DD HH24:MI:SS') as "datum",
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
    trunc(t.wert / 10.0, 1) as "temperatur"
  from bad b
  join becken be on b.id = be.badid
  join temperatur t on be.id = t.beckenid
  left join katalog kt on be.typ = kt.itemid and kt.gruppe = 1
  where t.datum >= '${FROM_DATE}'
    and t.datum < '${TO_DATE}'
  order by 1, 3
) TO STDOUT WITH (FORMAT csv, HEADER false, DELIMITER ';');
SQL
} > "$TMP_FILE"

mv "$TMP_FILE" "$OUT_FILE"

echo "Wrote $OUT_FILE"
