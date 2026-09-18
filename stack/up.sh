#!/usr/bin/env bash
# Bring up the demo estate and say where it landed. One command, no order to remember:
# Compose starts what each system's own stack file declares, in the order it declares it.
#
#   ./up.sh                         # Odoo + Chatwoot + Lago
#   SUPPORT=zammad ./up.sh          # a different system in a slot
#   ./up.sh --down                  # stop, keep the data
#   ./up.sh --wipe                  # stop and DELETE every volume of this project
set -euo pipefail
cd "$(dirname "$0")"

export CRM="${CRM:-odoo}" SUPPORT="${SUPPORT:-chatwoot}" BILLING="${BILLING:-lago}"
PROJECT=account-health-demo
# This estate is loaded from a book, so the CRM starts empty rather than with Odoo's own
# demo companies mixed into the story.
export ODOO_DEMO_DATA="${ODOO_DEMO_DATA:-false}"

case "${1:-}" in
  --down) exec docker compose down;;
  --wipe)
    echo "This deletes every volume of the '$PROJECT' project — all three systems' data." >&2
    read -r -p "Type the project name to confirm: " answer
    [ "$answer" = "$PROJECT" ] || { echo "not confirmed" >&2; exit 1; }
    exec docker compose down -v;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2;;
esac

# The stacks live in sibling realms. Say which one is missing rather than letting
# Compose report a path that means nothing to someone who has never seen this layout.
for realm in "realm-$CRM" "realm-$SUPPORT" "realm-$BILLING"; do
  [ -f "../../$realm/stack/compose.yml" ] || {
    echo "Missing ../../$realm/stack/compose.yml" >&2
    echo "Clone $realm beside this realm (they share one parent directory) and re-run." >&2
    exit 1
  }
done

docker compose up -d --wait

# Each system's first boot leaves its sign-in and API credentials in its own state
# volume. Read them back here so nobody has to go looking.
state() { docker run --rm -v "${PROJECT}_$1:/state:ro" alpine sh -c "cat /state/$2 2>/dev/null" | grep "^$3=" | cut -d= -f2-; }

cat <<OUT

The estate is up. Each product is the full product — sign in and use it.

  Odoo      http://localhost:${ODOO_PORT:-8069}      $(state odoo-state odoo.env ODOO_LOGIN) / $(state odoo-state odoo.env ODOO_PASSWORD)
  Chatwoot  http://localhost:${CHATWOOT_PORT:-3100}      $(state chatwoot-state chatwoot.env CHATWOOT_LOGIN) / $(state chatwoot-state chatwoot.env CHATWOOT_PASSWORD)
  Lago      http://localhost:${LAGO_FRONT_PORT:-8180}      demo@example.com / $(state lago-state lago.env LAGO_ORG_USER_PASSWORD)

API credentials for the realms are in the volumes ${PROJECT}_{odoo,chatwoot,lago}-state.
OUT
