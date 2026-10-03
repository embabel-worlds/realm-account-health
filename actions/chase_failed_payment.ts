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

/*
 * The customer's open support cases, and when the customer last wrote on each: a chase that takes
 * no notice of an open case reads as not listening. Those messages are written by the customer, so
 * the host marks this run as having read text from outside the business, and every request it
 * raises tells the approver the draft came after it. A desk that cannot be read costs the mention,
 * not the chase.
 */
const threads = await gateway.cypher.query({ cypher: `
  MATCH (lb:LagoBooks {scope:'all'})-[:HAS_INVOICE]->(i:LagoInvoice)
  WHERE i.paymentStatus = 'failed'
  WITH DISTINCT split(i.customerUrl, '//')[1] AS domain
  MATCH (d:ChatwootDesk {status:'open'})-[:HAS_CASE]->(c:ChatwootConversation)
  WHERE c.accountKey = domain
  MATCH (c)-[:HAS_MESSAGE]->(m:ChatwootMessage)
  RETURN domain, c.id AS conversation, c.subject AS subject, m.messageType AS type, m.sentAt AS at
` })
if (threads.warnings.length) console.log(`open cases not mentioned: ${threads.warnings.join('; ')}`)
/*
 * One line per open case on [domain] that the customer wrote on, or nothing. Filtered here rather
 * than in the query: Chatwoot cannot filter a thread by sender, and a filter it cannot absorb comes
 * back as a warning, which this routine reads as a partial answer. Type 0 is a message in.
 */
function openCases(domain: unknown): string {
  if (threads.warnings.length) return ''
  const lastHeard = new Map<string, { subject: string; at: number }>()
  for (const t of threads.rows as Record<string, unknown>[]) {
    if (t.domain !== domain || Number(t.type) !== 0) continue
    const seen = lastHeard.get(String(t.conversation))
    if (!seen || Number(t.at) > seen.at) lastHeard.set(String(t.conversation), { subject: String(t.subject), at: Number(t.at) })
  }
  if (lastHeard.size === 0) return ''
  const said = [...lastHeard].map(([id, c]) =>
    `#${id} "${c.subject}" (customer last wrote ${new Date(c.at * 1000).toISOString().slice(0, 10)})`)
  return ` Open with support: ${said.join('; ')}.`
}

const already = chasing.rows.map((r: Record<string, unknown>) => String(r.summary ?? ''))
/*
 * `now` and `dryRun` are bindings the runner declares only when it provides them, so referencing
 * one it was not given throws a ReferenceError rather than yielding undefined. This handler is
 * signal-driven and normally gets both — but its sibling was reached outside the duty that binds
 * ITS row, and answered a user with the resulting stack trace. A handler should not depend on being
 * invoked the way its author expected.
 *
 * `now` has an obvious fallback and `dryRun` a safe one: do the work for real, which is what an
 * unbound dryRun has always meant.
 */
const asOf = typeof now === 'undefined' ? new Date().toISOString() : now
const chasingDryRun = typeof dryRun !== 'undefined' && dryRun
const due = new Date(new Date(asOf).getTime() + FOLLOW_UP_DAYS * 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
/* A request the gateway answered with instead of making the call, when the agent may only ask. */
function isRequest(answer: unknown): answer is { requested: string; status: string } {
  return typeof answer === 'object' && answer !== null && 'requested' in answer
}

const chased: string[] = []
const asked: string[] = []
const skipped: string[] = []

/*
 * BEFORE CHASING, ASK THE COLLEAGUE WHO KNOWS THE ACCOUNT. Steward keeps account health; a chase
 * that lands on an account already at risk needs a lighter hand. The account's risk rows go as an
 * attachment, run when asked, so Steward answers from what the books say and not from a search of
 * its own that can miss. The answer is cited in the note, and an account Steward calls at risk is
 * chased with care. A host without colleague threads, or a Steward that may not be asked, costs the
 * question, never the chase.
 */
async function askSteward(domain: unknown, name: unknown): Promise<string> {
  try {
    const asked = await gateway.threads.ask({
      agent: 'steward',
      text: `Before I chase a failed payment from ${name}: is this account at risk, and why? ` +
        `The attached rows are HealthAtRiskAccounts for it; no row means it is not at risk. ` +
        `Begin your answer with AT RISK or NOT AT RISK, then the reason.`,
      attachments: [{ kind: 'view', label: 'HealthAtRiskAccounts', args: { account: String(domain) }, title: `Risk for ${name ?? domain}` }],
    }) as { answered?: boolean, text?: string, refused?: string, threadId?: string, attachments?: { properties?: Record<string, unknown> }[] }
    if (!asked?.answered) {
      console.log(`steward not asked about ${domain}: ${asked?.refused ?? 'no answer'}`)
      return ''
    }
    // The verdict is the answer's first words, as asked: "not at risk" contains "at risk", so a
    // search of the prose would read every reassurance as a warning.
    const atRisk = /^\W*at[ -]risk\b/i.test(asked.text ?? '')
    const cited = String(asked.text ?? '').replace(/\s+/g, ' ').slice(0, 240)
    return atRisk
      ? ` Chase with care: Steward says this account is at risk ("${cited}", thread ${asked.threadId}).`
      : ` Steward on this account: "${cited}" (thread ${asked.threadId}).`
  } catch (e) {
    console.log(`steward could not be asked about ${domain}: ${e}`)
    return ''
  }
}

for (const [n, row] of failed.rows.entries()) {
  const invoice = String(row.invoice)
  if (already.some(s => s.includes(invoice))) {
    skipped.push(invoice)
    continue
  }
  const owed = `${row.currency} ${Number(row.owed).toLocaleString('en-US')}`
  const steward = await askSteward(row.domain, (row.customer as Record<string, unknown> | undefined)?.name ?? row.domain)
  const note = `Payment for invoice ${invoice} (${owed}) failed. Chasing: follow-up due ${due}.${openCases(row.domain)}${steward}`
  if (chasingDryRun) {
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
