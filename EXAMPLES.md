# Worked examples

Every query here names no product: it is written against realm-business-vocabulary's types and
edges, so it runs over whichever CRM, helpdesk and billing system the world has. Money is per
currency, never summed across. `accountKey` is a company's domain, matched exactly: `acme.com`,
`acme.se` and `acmegroup.com` are three accounts, however alike their names.

## One account: ask each system about that domain alone

```cypher
// Its open support cases (the case carries accountKey, so the helpdesk is asked for this company)
MATCH (c:SupportCase)
WHERE c.accountKey = 'acme.com' AND c.status = 'open'
RETURN c.subject, c.priority, c.openedOn

// What it owes, per currency
MATCH (a:CustomerAccount {accountKey: 'acme.com'})-[:BILLED_AS]->(:BillingCustomer)-[:HAS_INVOICE]->(i:BillingInvoice)
WHERE i.paymentStatus <> 'succeeded'
RETURN i.currency AS currency, sum(i.amount - i.amountPaid) AS owed, count(i) AS unpaidInvoices

// Its open deals, per currency, unweighted
MATCH (a:CustomerAccount {accountKey: 'acme.com'})-[:TRACKED_AS]->(:CrmAccount)-[:HAS_OPPORTUNITY]->(o:Opportunity)
WHERE o.status = 'open'
RETURN o.currency AS currency, sum(o.amount) AS openPipeline, collect(o.title) AS deals
```

The same, by name: `HealthCasesForAccount`, `HealthReceivablesForAccount`,
`HealthPipelineForAccount`, `HealthRecurringForAccount`, each with `{accountKey: 'acme.com'}`. A
name becomes a domain through `HealthFindAccount {name: 'Acme AB'}`, which matches exactly.

## The whole book: sweep by the bare label, then join through the spine

```cypher
// Accounts owing money while waiting on support, per currency
MATCH (c:SupportCase) WHERE c.status = 'open'
WITH c, c.accountKey AS domain
MATCH (a:CustomerAccount {accountKey: domain})
WITH a, count(c) AS openCases
MATCH (i:BillingInvoice) WHERE i.paymentStatus <> 'succeeded'
MATCH (bc:BillingCustomer)
MATCH (a)-[:BILLED_AS]->(bc)-[:HAS_INVOICE]->(i)
RETURN a.accountKey, a.name, i.currency AS currency, sum(i.amount - i.amountPaid) AS owed, openCases
ORDER BY owed DESC

// Billed, unknown to the CRM: a set, then a negation
MATCH (k:CrmAccount)
MATCH (ka:CustomerAccount)-[:TRACKED_AS]->(k)
WITH collect(DISTINCT ka.accountKey) AS tracked
MATCH (bc:BillingCustomer)
MATCH (a:CustomerAccount)-[:BILLED_AS]->(bc)
WHERE NOT a.accountKey IN tracked
RETURN a.accountKey, a.name, bc.email
```

Written the other way round, out from every account (`MATCH (a:CustomerAccount)-[:HAS_CASE]->(c)`),
the book-wide questions ask each system once per account and are refused above a few hundred
accounts. Those are `HealthOwingAndWaiting` and `HealthBilledButUnknownToCrm` by name.

## Conclusions

```cypher
// Why one account is at risk: every reason that holds is its own property
MATCH (a:AtRiskAccount) WHERE a.accountKey = 'acme.com'
RETURN a.riskUnpaidWhileWaiting, a.riskOpenDealsWhileWaiting, a.riskFailedPayments,
       a.riskRenewsOn, a.riskLongestThread, a.riskHighPriorityCases, a.riskBilledUnknownToCrm
```
