#!/usr/bin/env python3
"""Generate schema, index and loaddb data files for the consistency-check benchmark.

Tables of three sizes so that bucket balancing matters: 8 large, 8 medium, 8 small.
Every table: INT primary key, INT secondary index, VARCHAR secondary index, ~180 byte payload.
"""
import os, sys

out = sys.argv[1] if len(sys.argv) > 1 else "."
scale = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
sizes = [int(1_000_000 * scale)] * 8 + [int(300_000 * scale)] * 8 + [int(50_000 * scale)] * 8
tables = [f"t{i+1:02d}" for i in range(len(sizes))]

with open(os.path.join(out, "schema.sql"), "w") as f:
    for t in tables:
        f.write(f"CREATE TABLE {t} (id INT PRIMARY KEY, k1 INT, k2 VARCHAR(32), payload VARCHAR(256));\n")
with open(os.path.join(out, "index.sql"), "w") as f:
    for t in tables:
        f.write(f"CREATE INDEX i_{t}_k1 ON {t} (k1);\nCREATE INDEX i_{t}_k2 ON {t} (k2);\n")
with open(os.path.join(out, "tables.txt"), "w") as f:
    f.write("\n".join(tables) + "\n")
with open(os.path.join(out, "table_sizes.txt"), "w") as f:
    for t, n in zip(tables, sizes):
        f.write(f"{t} {n}\n")

alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
def payload(i):
    x = (i * 2654435761) & 0xFFFFFFFF
    chunk = "".join(alphabet[(x >> (k * 5)) % 36] for k in range(6))
    return (chunk * 30)[:180]

with open(os.path.join(out, "data.txt"), "w") as f:
    for t, n in zip(tables, sizes):
        f.write(f"%class {t} (id k1 k2 payload)\n")
        for i in range(1, n + 1):
            f.write(f"{i} {(i * 7919) % 1000003} 'k{(i * 104729) % 9999991:08d}' '{payload(i)}'\n")
print("rows:", sum(sizes), "tables:", len(tables))
