# realm-account-health

Which customers are in trouble, which are ready for more, and what the CRM does not know about
them — read across a CRM, a helpdesk and a billing system, **naming no product**. Every view,
rule and judgement is written against [realm-business-vocabulary](https://github.com/embabel-worlds/realm-business-vocabulary)'s
types, edges and properties, and meets on `CustomerAccount`, the spine each product realm keys. The
same answers come from whichever CRM, helpdesk and billing system the world has, so long as their
realms sign the vocabulary's contract. Nothing is stored: each answer is read when it is asked for.

**The reference stack** is Odoo, Chatwoot and Lago, below. Nothing in the read side names them; the
one place a product still appears is the write side of the agents (see "What is still product-bound").

**Open it:** `/apps/account-health/account-signals.html` — a map of every account that matters (red
and green dots sized by money at stake), a split inbox underneath with every reason stacked on
each account, the CRM's own notes set beside what support is dealing with, and an ask bar.

## Run it

Everything is on `main` of each repo. Clone the five realms side by side (they share one parent
directory, which is also what an appliance mounts as `/realms`):

```
realm-business-vocabulary  realm-odoo  realm-chatwoot  realm-lago  realm-account-health
```

```sh
cd realm-account-health/stack
./up.sh                                          # Odoo + Chatwoot + Lago, in Docker; prints sign-ins
./load.sh --book <sample-business-data>/book      # the same story into all three, via their own APIs
./connect.sh >> <appliance>/secrets.env           # the three API credentials; then restart the appliance
```

Install the realms in the order `connect.sh` prints (vocabulary, the three products, then this
one), and open `/apps/account-health/account-signals.html`. People keep using Odoo, Chatwoot and
Lago exactly as before: each is the full product with its own UI, and what they change there is
what the next read here sees.

`tests/verify.sh` in each realm reconciles it against its own product; run this realm's last.

## Models judge, rules conclude, views project

| | Where | What |
|---|---|---|
| **Facts** | `views/health.yml` | Per-account facts, each reading ONE system; conjunctions that are one honest query; `HealthKnownAccounts`, which reads every system in full so every company is an account. |
| **Models judge** | `views/judgement.yml` | `HealthCaseTriage` — how much each open case hurts the customer, and their mood, from their own words. `HealthCrmAwareness` — does anything sales wrote touch the topic. Materialised, 6h. |
| **Rules conclude** | `rules/` | `AtRiskAccount` — one definition, seven independent clauses across three systems, each recording its own reason. `SHARES_ISSUE` — two accounts with an open case in the same product area. `POSSIBLY_WITHHELD_OVER` — an unpaid invoice and a case raised before it fell due. Computed when asked; nothing stored. |
| **Views project** | `views/conclusions.yml` | The small view per rule set that carries its conclusion to every surface, and is what makes the rules run. |

Why a rule set and not a view for `AtRiskAccount`: as a view it is a seven-way `OR` that cannot
say which arm was true for an account and that nobody can extend. As rules, each clause is
independent, the reasons are read off the account, and another realm — a project tracker — can add
"work we promised them is stuck" as a clause **from its own package**.

## Two colleagues: Steward and Chaser

The realm proposes two agents, in `agents/`. They arrive off duty with nobody answering for them:
a realm cannot appoint a sponsor or put its own agent to work, so adopting one is a person's
decision — sponsor it, sign it, and put it on duty, observing first.

| Agent | Job | Duties (the view whose rows are violations) | Routine |
|---|---|---|---|
| Steward | keeps account trouble in front of the account's owner | every at-risk account has a follow-up scheduled (`StewardUnacknowledgedRisk`); every at-risk renewal inside 60 days has a call booked (`StewardRenewalsWithoutCall`) | none |
| Chaser | makes sure what we are owed is chased, and what we sold is billed | no invoice 14 days overdue goes unchased (`ChaserUnchasedOverdue`); every account with a won deal has an active subscription (`ChaserWonWithoutSubscription`) | `chase-failed-payment` |

The duty views are in `views/agents.yml`; an empty answer is the duty kept. Duties are declared
and shown today, and run once duties do (business agents step 4).

**Chaser's routine** notes a failed payment on the customer in the CRM and schedules a follow-up
to chase it, using the CRM realm's own verbs (realm-odoo's `addNote` and `scheduleFollowUp`). It skips any invoice a
follow-up already names, whoever scheduled it, so it is safe to run again. It fires on
`view.ChaserFailedPayments.changed`, which needs a watch on that view delivering as a signal —
a watch belongs to whoever wants it, so a realm cannot ship one. Adopting Chaser means creating it:

```sh
curl -X POST "$APPLIANCE/api/v1/watches" -H 'Content-Type: application/json' -u "$AUTH" \
  -d '{"lensId":"ChaserFailedPayments","cron":"0 */15 * * * *","delivery":{"channel":"signal"},"diffSpec":{"keyPath":"invoice"}}'
```

`keyPath` names the column that identifies a row; without it a watch cannot diff a table and every
run ends `RESULT_NOT_DIFFABLE`. Events must be on (`assistant.events.enabled`) for the signal to
reach the routine. The routine's output is in Activity, not in the server's log.

**Observing is enforced by the appliance**, which refuses an observing routine's writes and records
them as calls it would have made (embabel/me#1840). **On duty, Chaser asks first**: its proposed
authority makes each CRM note and follow-up a request a person approves in the Approvals window
(embabel/me#1854), until its sponsor signs a wider grant.

## Needs

- `realm-business-vocabulary` (the `CustomerAccount` spine and the shared types), then one realm
  per slot: a CRM (`realm-odoo`), a helpdesk (`realm-chatwoot`), billing (`realm-lago`).
- A host with realm-declared spines (embabel/me#1340), and — for this realm's shape of query —
  #1351 (one label reached two ways) and #1354 (a materialised view's cache can be seen).
- A company is an account once some system's realm has keyed it, which happens when that system
  is read. The app asks `HealthKnownAccounts` first, which reads every system in full by its
  vocabulary label.
- Each product realm must sign the vocabulary's contract, including "Reading a whole system" in its
  README: a bare parent label (`MATCH (c:SupportCase)`) reads the whole system, and the spine edges
  (`TRACKED_AS`, `HAS_CASE`, `BILLED_AS`) declare `ridesHub` over exactly that sweep.
- At scale, two engine fixes: embabel/me#3702 (a bare-label sweep is skipped when a spine edge also
  reaches it, so the edge fetches once per account and is refused past 200 accounts) and #3703 (a
  bare-label read does not mark the spine built, so answers warn `SPINE_NOT_BUILT`). Without them
  every answer is still right on a book of a few hundred accounts.

## How every query is shaped, and why

A question about the whole book starts with a SWEEP by the bare vocabulary label, then joins to
accounts. A `SupportCase` carries `accountKey` (the contract asks it to), so its account is a value
match; a CRM or billing record does not, so the join is the spine edge, which rides the sweep:

```cypher
MATCH (o:Opportunity)                                         // the whole CRM's deals, one door
MATCH (k:CrmAccount)                                          // every company the CRM knows
MATCH (a:CustomerAccount)-[:TRACKED_AS]->(k)-[:HAS_OPPORTUNITY]->(o)
```

Written the other way round — out from each account — the answers are the same on a small book and
refused on a real one.

## What is still product-bound

**The agents' writes.** Chaser's routine (`actions/chase_failed_payment.ts`) and Steward's repair
(`actions/acknowledge_risk.ts`) write a note and schedule a follow-up through the CRM realm's own
verbs, and `agents/chaser.yml` grants Odoo's. The vocabulary declares types and edges, not verbs, so
a write cannot yet be said once for every CRM. The duties those agents keep (`views/agents.yml`)
name no product.

## Known limits, stated rather than hidden

- **Read views one at a time.** Views that reach the same records, run concurrently, return wrong
  rows and report success (embabel/me#1350). The app does; so should anything else.
- **A model can be wrong.** The awareness judge called a customer unaware whose notes said "custom
  reporting needs" while their case asked for a report builder. The app calls a blind spot only
  where the model AND a literal word test agree, and always shows the notes.
- **"Which accounts owe us the most?"** in words drops the amount (left red in the battery). The
  view is right.
- Billing sees ACTIVE subscriptions only, so churn cannot be answered (embabel/me#1346).

## Verify

`AUTH=user:pass sh tests/verify.sh` — every view by name; the views against each other; **every
rule clause recomputed from the facts**; the judgements stable across reads and within their
vocabularies; the app served; and `tests/questions.yml` replayed through the ask surface,
including three questions the sources cannot answer, asked three times each.
