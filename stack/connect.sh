#!/usr/bin/env bash
# What an Embabel appliance needs in order to read this estate: the three API credentials, as
# the env lines the product realms look for. Printed, never written — where an appliance keeps
# its secrets is its own business, and appending to someone's secrets file unasked is not a
# favour.
#
#   ./connect.sh                                  # look at them
#   ./connect.sh >> ~/embabel/worlds/secrets.env   # give them to an appliance, then restart it
#
# Each product's first boot left its credentials in its own state volume, which is why this
# needs the estate to be up (./up.sh) and nothing else. Lines go to stdout; everything a
# person needs to READ goes to stderr, so the redirect above stays clean.
set -euo pipefail
cd "$(dirname "$0")"

CRM="${CRM:-odoo}" SUPPORT="${SUPPORT:-chatwoot}" BILLING="${BILLING:-lago}"
PROJECT=account-health-demo

# slot realm : the name it has in the volume : the name the realm's apis.yml reads
WANTED=(
  "odoo:ODOO_API_KEY:ODOO_API_KEY"
  "chatwoot:CHATWOOT_API_TOKEN:CHATWOOT_API_TOKEN"
  "lago:LAGO_ORG_API_KEY:LAGO_API_KEY"
)

echo "# account-health demo estate — API credentials for realm-$CRM, realm-$SUPPORT, realm-$BILLING"
for slot in "$CRM" "$SUPPORT" "$BILLING"; do
  found=""
  for want in "${WANTED[@]}"; do
    IFS=: read -r realm have name <<<"$want"
    [ "$realm" = "$slot" ] || continue
    found=1
    value=$(docker run --rm -v "${PROJECT}_${realm}-state:/state:ro" alpine sh -c "cat /state/$realm.env 2>/dev/null" | grep "^$have=" | cut -d= -f2- || true)
    [ -n "$value" ] || { echo "No $have in the $realm state volume. Is the estate up? Run ./up.sh first." >&2; exit 1; }
    echo "$name=$value"
  done
  [ -n "$found" ] || echo "realm-$slot: this script does not know which credential it needs; see that realm's apis/apis.yml." >&2
done

cat >&2 <<OUT

Give those to the appliance and restart it. Then install the realms IN THIS ORDER — a realm
cannot yet declare that it needs another, and each of these stands on the one before:

  1. realm-business-vocabulary     the CustomerAccount spine and the shared types
  2. realm-$CRM   realm-$SUPPORT   realm-$BILLING     in any order
  3. realm-account-health          the views, rules and the app

With the realm checkouts mounted into the appliance, that is install_realm_from_path for each
(or the console's "install from path"). Then open:

  <appliance>/apps/account-health/account-signals.html

The products are reached from INSIDE the appliance's container as host.docker.internal; each
product realm's apis/ spec carries that address, and is the one line to edit for a real install.
OUT
