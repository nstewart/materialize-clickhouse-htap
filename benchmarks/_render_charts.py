"""Regenerate README reaction-time charts + table values in the README's compact
format, using existing response times + new freshness medians. Freshness is the
median across two n=21 concurrent-probe runs (~42 samples), all three paths
watching the same logical event (the canary inventory row): Materialize via
SUBSCRIBE, via-MZ via inventory_snapshots, standalone via opt_inventory. Only
freshness/totals/bars change; response times are unaffected by the flush/poll
tuning and are carried over."""
from run_benchmarks import _lin_pos, _nice_axis, fmt_ms

# Medians across two n=21 runs (run1 / run2):
#   Materialize                214.9 / 153.6  -> 184.3
#   ClickHouse via Materialize 687.8 / 714.3  -> 701.1
#   ClickHouse standalone      595.6 / 416.7  -> 506.2  (one 30s tail outlier in run1)
FRESH_MZ, FRESH_CH, FRESH_CHO = 184.3, 701.1, 506.2
NAME_COL = len("ClickHouse (via Materialize)")
BAR_W = 46

def bar_str(cdc, batch, resp, cap):
    total = cdc + batch + resp
    tc = _lin_pos(total, cap, BAR_W)
    if total > 0:
        cc = round(tc * cdc / total)
        bc = round(tc * batch / total)
        rc = tc - cc - bc
    else:
        cc = bc = rc = 0
    return "░" * cc + "▒" * bc + "█" * rc

def render(title, rows):
    """rows: list of (name, cdc, batch, resp). Renders one compact chart."""
    cap, step = _nice_axis(max(c + b + r for _, c, b, r in rows))
    rows = sorted(rows, key=lambda x: x[1] + x[2] + x[3])
    print(title)
    for name, cdc, batch, resp in rows:
        bar = bar_str(cdc, batch, resp, cap)
        total = cdc + batch + resp
        line = f"  {name:<{NAME_COL}}  {bar}"
        line = f"{line:<{2 + NAME_COL + 2 + BAR_W + 2}}({fmt_ms(total)})"
        print(line)
    # axis
    prefix = " " * (2 + NAME_COL + 2)
    n_ticks = int(round(cap / step)) + 1
    tick = [" "] * (BAR_W + 1)
    lbl = [" "] * (BAR_W + 14)
    for i in range(n_ticks):
        ms = i * step
        pos = _lin_pos(ms, cap, BAR_W)
        if pos > BAR_W:
            break
        tick[pos] = "|"
        if ms == 0:
            s = "0"
        elif ms >= 1000:
            s = f"{ms/1000:g}s"
        else:
            s = f"{int(round(ms))}ms"
        start = max(0, pos - len(s) // 2)
        for j, ch in enumerate(s):
            if 0 <= start + j < len(lbl):
                lbl[start + j] = ch
    print(prefix + "".join(tick))
    print(prefix + "".join(lbl).rstrip())
    print()

def total(cdc, batch, resp):
    return fmt_ms(cdc + batch + resp)

# ---- Operational ----
# (name, freshness, batch, response)
INV = [("Postgres",0,0,224.4),("Materialize",FRESH_MZ,0,24.2),
       ("ClickHouse (via Materialize)",FRESH_CH,0,11.5),("ClickHouse (standalone)",FRESH_CHO,0,10.6)]
CUST = [("Postgres",0,0,2030.0),("Materialize",FRESH_MZ,0,68.8),
        ("ClickHouse (via Materialize)",FRESH_CH,0,1050.0),("ClickHouse (standalone)",FRESH_CHO,500.0,301.5)]
PROD = [("Postgres",0,0,4240.0),("Materialize",FRESH_MZ,0,14.4),
        ("ClickHouse (via Materialize)",FRESH_CH,0,2070.0),("ClickHouse (standalone)",FRESH_CHO,2500.0,13.7)]
# ---- Analytical ----
HIST = [("Postgres",0,0,489.3),("Materialize",FRESH_MZ,0,3190.0),
        ("ClickHouse (via Materialize)",FRESH_CH,0,17.5),("ClickHouse (standalone)",FRESH_CHO,15000.0,27.7)]
XDIM = [("Postgres",0,0,3320.0),("Materialize",FRESH_MZ,0,4260.0),
        ("ClickHouse (via Materialize)",FRESH_CH,0,27.2),("ClickHouse (standalone)",FRESH_CHO,15000.0,7.3)]
COH = [("Postgres",0,0,1100.0),("Materialize",FRESH_MZ,0,5510.0),
       ("ClickHouse (via Materialize)",FRESH_CH,0,332.8),("ClickHouse (standalone)",FRESH_CHO,15000.0,114.3)]

print("=== TOP COMBINED ===\n")
render("Operational — Customer orders + spend rank", CUST)
render("Analytical — Revenue histogram ($50 buckets, 90 d)", HIST)
print("=== OPERATIONAL PER-QUERY ===\n")
render("Inventory lookup (by SKU)", INV)
render("Customer orders + lifetime metrics", CUST)
render("Product performance (by SKU)", PROD)
print("=== ANALYTICAL PER-QUERY ===\n")
render("Revenue histogram ($50 buckets, 90 d)", HIST)
render("Revenue by category × tier × day-of-week", XDIM)
render("Cohort retention (30/60/90 d)", COH)

print("=== TABLE TOTALS (freshness | batch | response | total) ===")
for label, data in [("INV",INV),("CUST",CUST),("PROD",PROD),("HIST",HIST),("XDIM",XDIM),("COH",COH)]:
    print(f"\n[{label}]")
    for name, cdc, batch, resp in sorted(data, key=lambda x: x[1]+x[2]+x[3]):
        bt = fmt_ms(batch) if batch > 0 else "—"
        fr = fmt_ms(cdc) if cdc > 0 else "0 ms"
        print(f"  {name:<30} {fr:>10} | {bt:>9} | {fmt_ms(resp):>9} | {total(cdc,batch,resp):>9}")
