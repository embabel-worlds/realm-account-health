#!/usr/bin/env bash
# Load a book into whichever three products this estate is running. One command: it reads
# each product's API credentials from the volume its first boot left them in, and hands
# the same book to each product's own loader.
#
#   ./load.sh --book ~/dev/sample-business-data/book
#   SUPPORT=zammad ./load.sh --book ...        # the loader comes from the realm in the slot
#   ./load.sh --book ... --remove              # undo
#
# A BOOK is a directory of product-neutral CSVs — crm/, support/, billing/ — joined by the
# customer's domain. This script knows nothing about what is in one, and neither does it
# know what a Chatwoot is: it runs realm-<slot>/seed/load_book.py for each slot. That is
# the whole arrangement. A new dataset needs a converter to the book format; a new product
# needs a load_book.py in its realm; nothing here changes for either.
#
# The book used to build this demo: github.com/embabel-worlds/sample-business-data (book/).
set -euo pipefail
cd "$(dirname "$0")"

CRM="${CRM:-odoo}" SUPPORT="${SUPPORT:-chatwoot}" BILLING="${BILLING:-lago}"
PROJECT=account-health-demo
BOOK="" EXTRA=()
while [ $# -gt 0 ]; do case "$1" in
  --book) BOOK="$2"; shift;;
  --remove) EXTRA+=(--remove);;
  *) echo "unknown argument: $1" >&2; exit 2;;
esac; shift; done

[ -n "$BOOK" ] || { echo "Say which book: ./load.sh --book <directory holding crm/ support/ billing/>" >&2; exit 2; }
for part in crm support billing; do
  [ -d "$BOOK/$part" ] || { echo "$BOOK has no $part/ directory, so it is not a book." >&2; exit 1; }
done

# Every loader refuses to run without --yes, because it cannot tell a demo from the real
# thing. This script can: it only ever talks to the estate it started itself, on localhost.
for realm in "$CRM" "$SUPPORT" "$BILLING"; do
  loader="../../realm-$realm/seed/load_book.py"
  [ -x "$loader" ] || { echo "realm-$realm has no seed/load_book.py, so it cannot take a book yet." >&2; exit 1; }
  state=$(docker run --rm -v "${PROJECT}_${realm}-state:/state:ro" alpine sh -c "cat /state/$realm.env") \
    || { echo "No credentials for $realm. Is the estate up? Run ./up.sh first." >&2; exit 1; }
  # Lago names its key for the organisation it belongs to; its loader asks for it plainly.
  env $(echo "$state" | grep -v PASSWORD | sed 's/^LAGO_ORG_API_KEY=/LAGO_API_KEY=/' | grep -E '^[A-Z_]+=' | xargs) \
    "$loader" --book "$BOOK" --yes "${EXTRA[@]+"${EXTRA[@]}"}"
done
