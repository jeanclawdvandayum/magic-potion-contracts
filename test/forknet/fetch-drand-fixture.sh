#!/usr/bin/env bash
# Fetch a recent drand evmnet round + signature into test/forknet/drand-fixture.json
# Usage: bash test/forknet/fetch-drand-fixture.sh [round_offset]
# The fixture pins (round, signature, round_time) so fork tests are reproducible
# without network access. Re-run to refresh when the pinned round gets old.
set -euo pipefail
CHAIN=04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3
OFFSET="${1:-1000}"
INFO=$(curl -fsS "https://api.drand.sh/$CHAIN/info")
LATEST=$(curl -fsS "https://api.drand.sh/$CHAIN/public/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["round"])')
ROUND=$((LATEST - OFFSET))
ROUND_JSON=$(curl -fsS "https://api.drand.sh/$CHAIN/public/$ROUND")
python3 - "$INFO" "$ROUND_JSON" > "$(dirname "$0")/drand-fixture.json" <<'PYEOF'
import json, sys
info = json.loads(sys.argv[1])
rnd = json.loads(sys.argv[2])
pubkey = info["public_key"]
pk_bytes = bytes.fromhex(pubkey)
assert len(pk_bytes) == 128, f"pubkey len {len(pk_bytes)}"
sig_bytes = bytes.fromhex(rnd["signature"])
assert len(sig_bytes) == 64, f"sig len {len(sig_bytes)}"
def be_word(b, i):
    return "0x" + b[i*32:(i+1)*32].hex()
# drand API serializes G2 as x.c1 || x.c0 || y.c1 || y.c0 (kyber marshaling).
# The BLS library + EIP-197 precompile want [x.c0, x.c1, y.c0, y.c1], so reorder.
fixture = {
    "chain_hash": info["hash"],
    "public_key": pubkey,
    "public_key_words": [be_word(pk_bytes, 1), be_word(pk_bytes, 0), be_word(pk_bytes, 3), be_word(pk_bytes, 2)],
    "genesis": info["genesis_time"],
    "period": info["period"],
    "round": rnd["round"],
    "round_time": info["genesis_time"] + (rnd["round"] - 1) * info["period"],
    "signature_words": [be_word(sig_bytes, i) for i in range(2)],
    "fetched_at": __import__("time").strftime("%Y-%m-%dT%H:%M:%SZ", __import__("time").gmtime()),
}
print(json.dumps(fixture, indent=2))
PYEOF
echo "fixture written:" && cat "$(dirname "$0")/drand-fixture.json"
