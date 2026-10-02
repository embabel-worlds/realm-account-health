/*
 * Steward's repair for one at-risk account nobody has picked up: a follow-up on the company in the
 * CRM, for its owner, saying why it is at risk. Run by the at-risk-acknowledged duty once per
 * violating row, which is bound as `violation`.
 *
 * The follow-up is what the duty's view counts as acknowledged, so once it exists the account
 * leaves the view on the next check — the duty is level-triggered, and a repair that lands is
 * simply not asked for again. Under Steward's authority it is a REQUEST a person approves first.
 *
 * Its arguments carry no date: asked again the next day, the same follow-up is the same request,
 * waiting or already decided, never a second one.
 */
const v = violation as Record<string, unknown>
const domain = String(v.accountKey ?? '')
if (!domain) {
  console.log('no account on this row — nothing to acknowledge')
  return { acknowledged: null }
}

// Through kg.query, which takes parameters, so the account's domain is bound and never spliced in.
const found = await gateway.kg.query({
  cypher: `
    MATCH (b:OdooBook {scope:'all'})-[:HAS_PARTNER]->(k:OdooCustomer)
    WITH k, split(split(toString(k.website), '//')[-1], '/')[0] AS host
    WITH k, CASE WHEN host STARTS WITH 'www.' THEN substring(host, 4) ELSE host END AS domain
    WHERE domain = $domain
    RETURN k.id AS id, k.name AS name
    LIMIT 1
  `,
  params: JSON.stringify({ domain }),
})
const company = found.rows[0]
if (!company) {
  // The CRM has never heard of it, so there is nowhere to put a follow-up. Left as a violation on
  // purpose: somebody has to bring the account into the CRM, and the duty keeps saying so.
  console.log(`${domain} is not in the CRM — it stays on the list until somebody adds it`)
  return { acknowledged: null }
}

const reasons = [
  v.failedPayments ? `${v.failedPayments} failed payment(s)` : '',
  v.owingWhileCaseOpen ? `owes ${v.owingWhileCaseOpen} while a case is open` : '',
  v.pipelineIntoTrouble ? `${v.pipelineIntoTrouble} of pipeline into an open case` : '',
  v.highPriorityCases ? `${v.highPriorityCases} high-priority case(s) open` : '',
  v.renewsOn ? `renews ${String(v.renewsOn).slice(0, 10)} with a case open` : '',
  v.unknownToCrm ? 'billed but unknown to the CRM' : '',
].filter(Boolean)

const summary = `Acknowledge: ${company.name} is at risk`
const note = `Steward found ${company.name} at risk and nobody following up: ${reasons.join('; ') || 'see its at-risk reasons'}.`
if (dryRun) {
  console.log(`WOULD schedule on ${company.name}: ${note}`)
  return { acknowledged: domain }
}
const answer = await gateway.odoo.partnerActivitySchedule({ ids: [Number(company.id)], summary, note })
console.log(`${typeof answer === 'object' && answer && 'requested' in answer ? 'asked to acknowledge' : 'acknowledged'} ${domain}: ${note}`)
return { acknowledged: domain }
