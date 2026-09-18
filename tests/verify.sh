#!/bin/sh
# Ground truth for realm-account-health. The three product realms each reconcile themselves
# against their own product (their tests/verify.sh); this realm adds no source, so what it
# must prove is different:
#
#   L1  every view answers BY NAME, and the account join underneath is really there (non-zero)
#   L2  the views agree with EACH OTHER — a conjunction view must equal the same conjunction
#       composed from the fact views, which is exactly how the app builds its signals
#   L3  the app is served
#   L4  the battery: questions in words reach the same figures, and the unanswerable stay so
#
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
set -e
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
: "${AUTH:?set AUTH (user:pass)}"
DIR="$(dirname "$0")"
APPLIANCE="$APPLIANCE" AUTH="$AUTH" python3 - "$DIR/questions.yml" <<'PY'
import json, os, subprocess, sys, yaml
base, auth, qfile = os.environ["APPLIANCE"], os.environ["AUTH"], sys.argv[1]
fail = 0
def post(path, body):
    out = subprocess.run(["curl", "-s", "-u", auth, "-X", "POST", base + path, "-H", "Content-Type: application/json",
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

print("== L1: every view answers by name ==")
NAMES = ["HealthOpenCasesByAccount", "HealthResolvedCasesByAccount", "HealthReceivablesByAccount", "HealthBillingByAccount",
         "HealthRecurringByAccount", "HealthPipelineByAccount", "HealthCrmRecordByAccount", "HealthCompanyNotesForOpenCases",
         "HealthDealNotesForOpenCases", "HealthContactNotesForOpenCases", "HealthSellingIntoTrouble", "HealthOwingAndWaiting",
         "HealthRevenueBehindCases", "HealthBilledButUnknownToCrm",
         "HealthAtRiskAccounts", "HealthSharedIssues", "HealthPossiblyWithheld", "HealthCaseTriage", "HealthCrmAwareness"]
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

print("== L2c: the JUDGEMENTS are stable, and legal ==")
# A materialised judgement must be the SAME judgement on the next read — that is what it is
# materialised for. (It was not, until the host could see its own cache: embabel/me#1354.)
again = view("HealthCaseTriage")
check("case triage is the same on a second read", V["HealthCaseTriage"], again)
check("impact is one of the four words", True, all(r["impact"] in ("blocked", "degraded", "inconvenienced", "asking") for r in again))
check("mood is one of the three words", True, all(r["mood"] in ("frustrated", "neutral", "positive") for r in again))
check("awareness is one of the two words", True, all(r["crmAwareness"] in ("aware", "unaware") for r in V["HealthCrmAwareness"]))

print("== L3: the app is served ==")
code = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-u", auth, base + "/apps/account-health/account-signals.html"],
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
print("ALL CHECKS PASS" if not fail else "SOME CHECKS FAILED"); sys.exit(fail)
PY
