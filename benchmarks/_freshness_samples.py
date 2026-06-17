"""Sample CDC freshness N times to get representative medians (probe is n=1/run)."""
import statistics
import time
from rich.console import Console

from run_benchmarks import (
    PG_DSN, MZ_DSN, CH_DSN,
    pg_connect, mz_connect, ch_connect,
    measure_freshness, fmt_ms,
)

console = Console()
pg_conn = pg_connect(PG_DSN)
mz_conn = mz_connect(MZ_DSN)
ch = ch_connect(CH_DSN)

N = 21
mz_s, ch_s, cho_s = [], [], []
for i in range(N):
    mz, chv, cho = measure_freshness(pg_conn, mz_conn, ch, True, console)
    mz_s.append(mz); ch_s.append(chv); cho_s.append(cho)
    time.sleep(1)

def report(name, xs):
    print(f"{name:32} median={fmt_ms(statistics.median(xs))}  "
          f"mean={fmt_ms(statistics.mean(xs))}  "
          f"min={fmt_ms(min(xs))}  max={fmt_ms(max(xs))}")

print("\n==== FRESHNESS SAMPLES (n=%d) ====" % N)
report("Materialize", mz_s)
report("ClickHouse (via Materialize)", ch_s)
report("ClickHouse (standalone/Debezium)", cho_s)
