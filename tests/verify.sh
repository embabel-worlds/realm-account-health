#!/bin/sh
# Ground truth for realm-account-health. The three product realms each reconcile themselves
# against their own product (their tests/verify.sh); this realm adds no source, so what it
# must prove is different:
#
#   L0  the realm names no product: every label and relationship in its views and rules is the
#       business vocabulary's, the spine's, or one this realm derives or projects itself
#   L1  every view answers BY NAME, and the account join underneath is really there (non-zero)
#   L2  the views agree with EACH OTHER — a conjunction view must equal the same conjunction
#       composed from the fact views, which is exactly how the app builds its signals
#   L2d the agents' duty views agree with the facts they are built from
#   L3  the app is served
#   L4  the battery: questions in words reach the same figures, and the unanswerable stay so
#   L5  text in: an email projected with ai.fromText resolves to the right account, reports the
#       same open cases and owed as the fact views, declines a personal address, and leaves
#       nothing behind. Needs an appliance with ai.fromText (embabel/me#3331): FROM_TEXT=1
#
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
set -e
# Either AUTH=user:pass or TOKEN=<appliance API key>. Both go to curl through a config file, so
# neither appears on a command line where `ps` would show it.
AUTHCFG=$(mktemp); trap 'rm -f "$AUTHCFG"' EXIT
if [ -n "${TOKEN:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTHCFG"
else printf 'user = "%s"\n' "${AUTH:?set AUTH (user:pass) or TOKEN}" > "$AUTHCFG"; fi
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
DIR="$(dirname "$0")"
APPLIANCE="$APPLIANCE" AUTH="$AUTHCFG" python3 - "$DIR/questions.yml" "$DIR/.." <<'PY'
import glob, json, os, re, subprocess, sys, yaml
base, auth, qfile, realm = os.environ["APPLIANCE"], os.environ["AUTH"], sys.argv[1], sys.argv[2]
fail = 0
def post(path, body):
    out = subprocess.run(["curl", "-s", "-K", auth, "-X", "POST", base + path, "-H", "Content-Type: application/json",
                          "-d", json.dumps(body)], capture_output=True, text=True).stdout
    return json.loads(out, strict=False)
def view(name):
    v = post("/api/v1/views/%s/invoke" % name, {"args": {}})
    if v.get("status") != "SUCCEEDED": raise SystemExit("view %s: %s" % (name, v.get("status")))
    return v.get("data") or []
def check(name, want, got):
    global fail
    ok = want == got
    print(("  ok   %s = %s" % (name, got)) if ok else ("  FAIL %s: expected %s, got %s" % (name, want, got)))
    if not ok: fail = 1
def keys(rows): return sorted(r["accountKey"] for r in rows)

print("== L0: the realm names no product ==")
# The vocabulary's own types and relationships (its README's table), the spine, and what this realm
# derives (rules), projects (from-text) or names itself. Anything else in a query is a product.
VOCAB_TYPES = {"CustomerAccount", "CrmAccount", "AccountContact", "AccountNote", "Opportunity", "FollowUp",
               "Meeting", "SupportCase", "SupportMessage", "BillingCustomer", "BillingSubscription",
               "BillingInvoice", "PaymentAttempt"}
VOCAB_RELS = {"TRACKED_AS", "HAS_ACCOUNT_CONTACT", "HAS_OPPORTUNITY", "HAS_NOTE", "FOLLOW_UP_ON", "MEETING_WITH",
              "HAS_CASE", "HAS_MESSAGE", "BILLED_AS", "HAS_SUBSCRIPTION", "HAS_INVOICE", "HAS_ATTEMPT"}
OWN = {"AtRiskAccount", "SHARES_ISSUE", "POSSIBLY_WITHHELD_OVER", "Attendee", "CustomerIssue", "RAISED",
       "WORKS_FOR", "TRACKED_BY"}
def queries():
    for f in sorted(glob.glob(os.path.join(realm, "views", "*.yml"))):
        for v in yaml.safe_load(open(f)) or []:
            yield "%s %s" % (os.path.basename(f), v["name"]), v.get("cypher", "")
    for f in sorted(glob.glob(os.path.join(realm, "rules", "*.yml"))):
        r = yaml.safe_load(open(f))
        for i, d in enumerate(r.get("requires") or []): yield "%s requires[%d]" % (os.path.basename(f), i), d.get("materialize", "")
        for i, d in enumerate(r.get("rules") or []): yield "%s rules[%d]" % (os.path.basename(f), i), d.get("derive", "") + " " + d.get("from", "")
named = 0
for where, q in queries():
    code = re.sub(r"'[^']*'", "''", re.sub(r"//[^\n]*", "", q))
    used = set(re.findall(r"\(\s*\w*\s*:\s*(\w+)", code)) | set(re.findall(r"\[\s*\w*\s*:\s*(\w+)", code))
    stray = sorted(used - VOCAB_TYPES - VOCAB_RELS - OWN)
    named += 1
    if stray: print("  FAIL %s names %s" % (where, stray)); fail = 1
print("  ok   %d queries read, every label and relationship the vocabulary's or the realm's own" % named if not fail else "")

# What the app asks first: every system read in full, so every company any of them knows is an account.
view_known = post("/api/v1/views/HealthKnownAccounts/invoke", {"args": {}})
print("== the accounts: %s ==" % json.dumps((view_known.get("data") or [{}])[0]))

print("== L1: every view answers by name ==")
NAMES = ["HealthKnownAccounts", "HealthOpenCaseCountsByAccount", "HealthUrgentCaseCountsByAccount", "HealthOpenCasesByAccount", "HealthResolvedCasesByAccount", "HealthReceivablesByAccount", "HealthBillingByAccount",
         "HealthRecurringByAccount", "HealthPipelineByAccount", "HealthCrmRecordByAccount", "HealthCompanyNotesForOpenCases",
         "HealthDealNotesForOpenCases", "HealthContactNotesForOpenCases", "HealthSellingIntoTrouble", "HealthOwingAndWaiting",
         "HealthRevenueBehindCases", "HealthBilledButUnknownToCrm",
         "HealthAtRiskAccounts", "HealthSharedIssues", "HealthPossiblyWithheld", "HealthCaseTriage", "HealthCrmAwareness",
         "StewardUnacknowledgedRisk", "StewardRenewalsWithoutCall", "ChaserUnchasedOverdue",
         "ChaserWonWithoutSubscription", "ChaserFailedPayments"]
V = {n: view(n) for n in NAMES}
for n in NAMES: print("  ok   %-34s %d rows" % (n, len(V[n])))
for n in ("HealthOpenCasesByAccount", "HealthBillingByAccount", "HealthCrmRecordByAccount"):
    # One per system. Zero here means that system's account join is not there, and every
    # conjunction below would pass vacuously.
    if not V[n]: print("  FAIL %s is empty — a product realm is not joined to CustomerAccount" % n); fail = 1

print("== L2: the views agree with each other ==")
cases = {r["accountKey"]: r for r in V["HealthOpenCasesByAccount"]}
owed = {r["accountKey"]: r for r in V["HealthReceivablesByAccount"]}
pipe = {r["accountKey"]: r for r in V["HealthPipelineByAccount"]}
recur = {r["accountKey"]: r for r in V["HealthRecurringByAccount"]}
billed = {r["accountKey"] for r in V["HealthBillingByAccount"]}
crm = {r["accountKey"] for r in V["HealthCrmRecordByAccount"]}
check("owing AND waiting", sorted(set(cases) & set(owed)), keys(V["HealthOwingAndWaiting"]))
check("selling into trouble", sorted(k for k in cases if pipe.get(k, {}).get("openPipeline", 0) > 0), keys(V["HealthSellingIntoTrouble"]))
check("revenue behind cases", sorted(set(cases) & set(recur)), keys(V["HealthRevenueBehindCases"]))
check("billed, unknown to the CRM", sorted(billed - crm), keys(V["HealthBilledButUnknownToCrm"]))
for r in V["HealthSellingIntoTrouble"]:
    check("pipeline for %s, both ways" % r["accountKey"], pipe[r["accountKey"]]["openPipeline"], r["openPipeline"])
for r in V["HealthOwingAndWaiting"]:
    check("owed by %s, both ways" % r["accountKey"], owed[r["accountKey"]]["owed"], r["owed"])

print("== L2b: the RULES conclude what the facts say ==")
# Each clause of rules/at-risk.yml, recomputed here from the fact views. A rule set is only as
# good as the facts it was given, and its `requires:` demands are what give it them: a clause
# that silently concluded over an unfetched system would be short here.
risk = {r["accountKey"]: r for r in V["HealthAtRiskAccounts"]}
def having(col): return sorted(k for k, r in risk.items() if r.get(col) is not None)
check("rule: owing and waiting", sorted(set(cases) & set(owed)), having("owingAndWaiting"))
check("rule: selling into trouble", sorted(k for k in cases if pipe.get(k, {}).get("openPipeline", 0) > 0), having("sellingIntoTrouble"))
check("rule: failed payments", sorted(k for k, r in owed.items() if r["failedInvoices"] > 0), having("failedPayments"))
check("rule: billed with no owner", sorted(billed - crm), having("billedWithNoOwner"))
check("rule: high-priority cases", sorted(k for k, r in cases.items() if r["highPriority"] > 0), having("highPriorityCases"))
check("rule: long threads (>= 15 replies)", sorted(k for k, r in cases.items() if (r["longestThread"] or 0) >= 15), having("longestThread"))
for r in V["HealthAtRiskAccounts"]:
    if r.get("sellingIntoTrouble") is not None:
        check("rule value: pipeline for %s" % r["accountKey"], pipe[r["accountKey"]]["openPipeline"], r["sellingIntoTrouble"])
# A derived edge is between two DIFFERENT accounts that both have an open case, once per pair.
pairs = [(r["accountKey"], r["otherKey"]) for r in V["HealthSharedIssues"]]
check("shared issue: both ends have an open case", True, all(a in cases and b in cases for a, b in pairs))
check("shared issue: each pair once, never an account with itself", True, len(set(pairs)) == len(pairs) and all(a < b for a, b in pairs))
check("possibly withheld: only accounts that owe AND wait", True, set(r["accountKey"] for r in V["HealthPossiblyWithheld"]) <= (set(cases) & set(owed)))

print("== L2d: the agents' duties agree with the facts ==")
check("failed payments = the failed invoices on the receivables", sorted(k for k, r in owed.items() for _ in range(r["failedInvoices"])),
      sorted(r["accountKey"] for r in V["ChaserFailedPayments"]))
check("unacknowledged risk is a subset of the accounts at risk", True,
      {r["accountKey"] for r in V["StewardUnacknowledgedRisk"]} <= set(risk))
check("unchased overdue invoices are unpaid ones", True,
      {r["accountKey"] for r in V["ChaserUnchasedOverdue"]} <= set(owed))
check("won without a subscription: never an account that has one", set(),
      {r["accountKey"] for r in V["ChaserWonWithoutSubscription"]} & set(recur))
counts = {r["accountKey"]: r["openCases"] for r in V["HealthOpenCaseCountsByAccount"]}
check("open-case counts = the detail view's counts", {k: r["openCases"] for k, r in cases.items()}, counts)
check("urgent counts = the detail view's high priority", {k: r["highPriority"] for k, r in cases.items() if r["highPriority"]},
      {r["accountKey"]: r["urgentCases"] for r in V["HealthUrgentCaseCountsByAccount"]})

print("== L2c: the JUDGEMENTS are stable, and legal ==")
# A materialised judgement must be the SAME judgement on the next read — that is what it is
# materialised for. (It was not, until the host could see its own cache: embabel/me#1354.)
again = view("HealthCaseTriage")
check("case triage is the same on a second read", V["HealthCaseTriage"], again)
check("impact is one of the four words", True, all(r["impact"] in ("blocked", "degraded", "inconvenienced", "asking") for r in again))
check("mood is one of the three words", True, all(r["mood"] in ("frustrated", "neutral", "positive") for r in again))
check("awareness is one of the two words", True, all(r["crmAwareness"] in ("aware", "unaware") for r in V["HealthCrmAwareness"]))

print("== L3: the app is served ==")
code = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-K", auth, base + "/apps/account-health/account-signals.html"],
                      capture_output=True, text=True).stdout
check("account-signals.html", "200", code)

print("== L4: the battery (tests/questions.yml) ==")
def figure(rows, column):
    return round(float(rows[0][column]), 2) if rows and column in rows[0] and rows[0][column] is not None else None
for case in yaml.safe_load(open(qfile)):
    q, exp = case["question"], case["expect"]
    if exp.get("declines"):
        counts = [len(post("/api/v1/admin/kg/ask", {"question": q}).get("rows") or []) for _ in range(exp.get("times", 3))]
        ok = all(c == 0 for c in counts)
        print(("  ok   " if ok else "  FAIL ") + "[cannot answer] " + q + " -> rows per run " + str(counts))
        fail |= (not ok); continue
    a = post("/api/v1/admin/kg/ask", {"question": q}); rows = a.get("rows") or []; ok = True; said = []
    if "matchesView" in exp:
        mv = exp["matchesView"]; want, got = figure(V[mv["name"]], mv["column"]), figure(rows, mv["column"])
        ok &= want is not None and want == got; said.append("%s=%s (view %s)" % (mv["column"], got, want))
    if exp.get("nonEmpty"):
        ok &= len(rows) > 0; said.append("%d rows" % len(rows))
    if "rows" in exp:
        ok &= len(rows) == len(V[exp["rows"]]); said.append("%d rows (view %d)" % (len(rows), len(V[exp["rows"]])))
    print(("  ok   " if ok else "  FAIL ") + q + " -> " + ", ".join(said))
    if not ok:
        fail = 1; print("       cypher: " + " ".join((a.get("cypher") or "").split())[:220])

print("== L5: text in (views/from-text.yml) ==")
if os.environ.get("FROM_TEXT") != "1":
    # Said out loud rather than passed quietly: on an appliance without ai.fromText this level
    # did not run, and a reader of the output must not take its absence for a pass.
    print("  SKIPPED: set FROM_TEXT=1 on an appliance with ai.fromText (embabel/me#3331)")
else:
    def view_with(name, args):
        return post("/api/v1/views/%s/invoke" % name, {"args": args})
    def projected_count():
        def one(label):
            r = post("/api/v1/admin/kg/cypher", {"cypher": "MATCH (n:%s) RETURN count(n) AS n" % label})
            return (r.get("rows") or [{"n": None}])[0]["n"]
        return {label: one(label) for label in ("Attendee", "CustomerIssue")}
    # northwind-traders.example is the seed book's "silent escalation" arc: an urgent case open
    # and money owed, so both columns have something to be wrong about.
    KEY = "northwind-traders.example"
    EMAIL = """From: Priya Raman <priya.raman@northwind-traders.example>
Subject: Month end is blocked again

Hi — the invoice export is still failing and it is blocking our month-end close, third month
running. Separately, Tom in IT says SSO keeps looping on Safari. Can someone call me today?
Priya Raman, Head of Finance"""
    before = projected_count()
    res = view_with("HealthWhatThisEmailRaises", {"email": EMAIL})
    rows = res.get("data") or []
    check("email view answered", "SUCCEEDED", res.get("status"))
    check("issues projected from the email", True, len(rows) >= 2)
    check("every issue resolved to %s" % KEY, [KEY] * len(rows), [r.get("accountKey") for r in rows])
    check("severities stay in the declared set", True, all(r.get("severity") in ("high", "medium", "low") for r in rows))
    open_by_key = {r["accountKey"]: r for r in V["HealthOpenCasesByAccount"]}
    owed_by_key = {r["accountKey"]: r for r in V["HealthReceivablesByAccount"]}
    want_cases = sorted(set(open_by_key.get(KEY, {}).get("subjects") or []))
    want_owed = round(float(owed_by_key[KEY]["owed"]), 2) if KEY in owed_by_key else 0.0
    for r in rows:
        check("open cases beside '%s'" % r.get("issue"), want_cases, sorted(r.get("openCases") or []))
        check("owed beside '%s'" % r.get("issue"), want_owed, round(float(r.get("owed") or 0), 2))
    # A personal address must come back DECLINED — said, not just an empty account column.
    gmail = view_with("HealthWhatThisEmailRaises", {"email": EMAIL.replace("priya.raman@northwind-traders.example", "priya.raman@gmail.com")})
    grows = gmail.get("data") or []
    check("a gmail sender resolves to no account", [None] * len(grows), [r.get("accountKey") for r in grows])
    told = json.dumps({k: v for k, v in gmail.items() if k != "data"}).lower()
    # A personal address can end two honest ways: the model names the company and the account
    # spine declines it (PROJECTION_DECLINED), or the model, seeing a gmail address, names no
    # company at all and the text is reported silent on it (PROJECTION_EMPTY). Either way the
    # response must say why there is no account; it must not just be empty.
    check("and the response says why there is no account", True, "declin" in told or "silent" in told)
    check("nothing projected was left behind", before, projected_count())
print("ALL CHECKS PASS" if not fail else "SOME CHECKS FAILED"); sys.exit(fail)
PY
