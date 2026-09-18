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
         "HealthRevenueBehindCases", "HealthBilledButUnknownToCrm"]
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
