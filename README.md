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
| **Facts** | `views/health.yml` | Per-account facts, each reading ONE system; conjunctions that are one honest query; `HealthKnownAccounts`, which reads every system in full so every company is an account; and the `…ForAccount` views (`HealthCasesForAccount`, `HealthReceivablesForAccount`, `HealthPipelineForAccount`, `HealthRecurringForAccount`), ONE account's facts, asked of each system for that account alone rather than read off the whole book; `HealthFindAccount`, a name to a domain, exactly. |
| **Models judge** | `views/judgement.yml` | `HealthCaseTriage` — how much each open case hurts the customer, and their mood, from their own words. `HealthCrmAwareness` — does anything sales wrote touch the topic. Materialised, 6h. |
| **Rules conclude** | `rules/` | `AtRiskAccount` — one definition, seven independent clauses across three systems, each recording its own reason. `SHARES_ISSUE` — two accounts with an open case in the same product area, concluded for one account at a time. `POSSIBLY_WITHHELD_OVER` — an unpaid invoice and a case raised before it fell due. Computed when asked; nothing stored. |
| **Views project** | `views/conclusions.yml` | The small view per rule set that carries its conclusion to every surface, and is what makes the rules run. `HealthSharedIssues` is by product AREA and needs no rule; `HealthSharedIssuesForAccount` reads `SHARES_ISSUE` for one account. |

Why a rule set and not a view for `AtRiskAccount`: as a view it is a seven-way `OR` that cannot
say which arm was true for an account and that nobody can extend. As rules, each clause is
independent, the reasons are read off the account, and another realm — a project tracker — can add
"work we promised them is stuck" as a clause **from its own package**.

## What the figures mean

- **One company, one account.** An account is keyed by its domain (`accountKey`). Near-named
  companies are DISTINCT accounts — `Acme`, `Acme AB` and `Acme Group` each have their own domain —
  so every `account` / `accountKey` parameter is a domain matched exactly, and `HealthFindAccount`
  matches a name exactly unless asked for `partial`.
- **Open** is status `open`: waiting on us. `pending` waits on the customer and is not counted —
  by the views and the rules alike.
- **Money is per currency.** Every view that sums money returns one row per account AND currency;
  nothing is added across currencies. The at-risk reasons are counts, dates and flags, never
  amounts, so they carry no currency; the amounts are in the fact views.
- **High priority** is urgent OR high. `owed` is `amount - amountPaid`; unpaid is payment not
  succeeded, which includes invoices not yet due. `openPipeline` is unweighted.

## One account, or the whole book

The book-wide views sweep each system once by its bare vocabulary label, which is right for "which
accounts…". Asked about ONE company, a sweep would read every record in every system to keep a
handful, so the `…ForAccount` views ask each system about that domain alone: a few source calls
whatever the book's size (`tests/verify.sh` L2e asserts the bound).

```sh
curl -u "$AUTH" -X POST "$APPLIANCE/api/v1/views/HealthReceivablesForAccount/invoke" \
  -H 'Content-Type: application/json' -d '{"args":{"accountKey":"acme.com"}}'
```

`HealthAtRiskAccounts {account}` is the exception, stated: the rule set's facts are demanded book-wide
whatever its argument, so `account` filters the conclusion and does not make it cheaper.

## Shared issues: by area, because pairs are quadratic

`HealthSharedIssues` used to list every PAIR of accounts sharing a product area, from `SHARES_ISSUE`.
Pairs grow with the square of the accounts in an area: on the scale book (eight areas, an open case
on one account in three) 2,000 accounts is ~27,000 pairs against the rule set's `maxPairs` of 5,000,
and 5,000 accounts ~170,000, past the engine's 50,000-fact budget. A relationship set past either
is refused whole, so the view failed by name and the battery's L1 stopped there. It now answers by
AREA — one desk sweep, one row per area, with every account affected — and the rule set takes an
`accountKey`, which `HealthSharedIssuesForAccount` passes, so the pairs are concluded for one account.

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

`AUTH=user:pass sh tests/verify.sh` — every view by name; the views against each other, per
currency; one account through the `…ForAccount` views, agreeing with the book in a bounded number
of source calls (`ONE_ACCOUNT_CALLS`, default 6); **every
rule clause recomputed from the facts**; the judgements stable across reads and within their
vocabularies; the app served; and `tests/questions.yml` replayed through the ask surface,
including three questions the sources cannot answer, asked three times each.
