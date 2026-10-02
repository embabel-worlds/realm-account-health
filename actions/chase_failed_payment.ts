/*
 * Chase every failed payment that nobody is chasing yet: a note on the customer saying what
 * failed, and a follow-up to chase it in three days.
 *
 * IDEMPOTENT BY WHAT IS IN THE CRM, not by remembering. A follow-up's summary names the invoice,
 * so an invoice already being chased is skipped, whoever scheduled it — a person who got there
 * first, or an earlier run. The signal says SOMETHING changed; this reads what is true now, so a
 * missed or repeated signal costs nothing.
 *
 * Literal queries only. `gateway.cypher.query` keeps each customer's type, which is what gives it
 * `addNote` and `scheduleFollowUp`, and it takes no parameters — so the failed invoices are
 * joined to their CRM customers in the query, and no value is ever spliced into one.
 */
const FOLLOW_UP_DAYS = 3

const failed = await gateway.cypher.query({ cypher: `
  MATCH (lb:LagoBooks {scope:'all'})-[:HAS_INVOICE]->(i:LagoInvoice)
  WHERE i.paymentStatus = 'failed'
  WITH i, split(i.customerUrl, '//')[1] AS domain
  MATCH (b:OdooBook {scope:'all'})-[:HAS_CUSTOMER]->(k:OdooCustomer)
  WITH i, domain, k, split(split(toString(k.website), '//')[-1], '/')[0] AS host
  WHERE CASE WHEN host STARTS WITH 'www.' THEN substring(host, 4) ELSE host END = domain
  RETURN i.number AS invoice, i.amountDueCents / 100.0 AS owed, i.currency AS currency,
         domain, k AS customer
` })
const chasing = await gateway.cypher.query({ cypher: `
  MATCH (b:OdooBook {scope:'all'})-[:HAS_ACTIVITY]->(t:OdooActivity)
  WHERE t.res_model = 'res.partner'
  RETURN t.summary AS summary
` })
if (failed.warnings.length || chasing.warnings.length) {
  // A source that failed or truncated reads as "nothing failed" or "nobody is chasing", and the
  // second would chase twice. Saying nothing is the safe answer to a partial read.
  console.log(`not chasing on a partial read: ${[...failed.warnings, ...chasing.warnings].join('; ')}`)
  return { chased: [], asked: [], skipped: [] }
}

const already = chasing.rows.map((r: Record<string, unknown>) => String(r.summary ?? ''))
const due = new Date(new Date(now).getTime() + FOLLOW_UP_DAYS * 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
/* A request the gateway answered with instead of making the call, when the agent may only ask. */
function isRequest(answer: unknown): answer is { requested: string; status: string } {
  return typeof answer === 'object' && answer !== null && 'requested' in answer
}

const chased: string[] = []
const asked: string[] = []
const skipped: string[] = []

for (const [n, row] of failed.rows.entries()) {
  const invoice = String(row.invoice)
  if (already.some(s => s.includes(invoice))) {
    skipped.push(invoice)
    continue
  }
  const owed = `${row.currency} ${Number(row.owed).toLocaleString('en-US')}`
  const note = `Payment for invoice ${invoice} (${owed}) failed. Chasing: follow-up due ${due}.`
  if (dryRun) {
    console.log(`WOULD note and follow up on ${row.domain}: ${note}`)
  } else {
    // Bound into program state so the row comes back as an OdooCustomer, with its methods.
    state.set(`failed_${n}`, row.customer)
    const customer = state.get(`failed_${n}`)
    const noted = await customer.addNote(note)
    const followed = await customer.scheduleFollowUp({ summary: `Chase failed payment ${invoice}`, due, note })
    // An agent that may only ASK gets requests back, not ids: say which happened, so the run's
    // record does not claim a chase a person has yet to approve.
    if (isRequest(noted) || isRequest(followed)) {
      console.log(`asked to chase ${invoice} on ${row.domain}: ${[noted, followed].filter(isRequest).map((r) => r.status).join(', ')}`)
      asked.push(invoice)
      continue
    }
    console.log(`chased ${invoice} on ${row.domain}`)
  }
  chased.push(invoice)
}
if (failed.rows.length === 0) console.log('no failed payment on a customer the CRM knows — nothing to chase')
return { chased, asked, skipped }
