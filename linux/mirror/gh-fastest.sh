#!/bin/bash
# =============================================================================
#  github-watchdog (linux) :: mirror :: gh-fastest.sh
#  Speed-test all GitHub mirror prefixes in mirrors.txt, print fastest first.
#  Results cached to mirrors-ranked.json (24h TTL).
#
#  Usage:
#    gh-fastest.sh                 # cached if <24h, else full test; print top 5
#    gh-fastest.sh --refresh       # force full re-test
#    gh-fastest.sh --top 10
#    gh-fastest.sh --timeout 6 --parallel 16
#    gh-fastest.sh --url "https://github.com/OWNER/REPO/archive/refs/heads/main.zip"
# =============================================================================
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIST="$HERE/mirrors.txt"
CACHE="$HERE/mirrors-ranked.json"
URL="https://github.com/cli/cli/archive/refs/heads/trunk.zip"
TOP=5
TIMEOUT=6
PARALLEL=16
REFRESH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --top)       TOP="${2:-5}"; shift 2;;
    --timeout)   TIMEOUT="${2:-6}"; shift 2;;
    --parallel)  PARALLEL="${2:-16}"; shift 2;;
    --url)       URL="${2:-}"; shift 2;;
    --refresh)   REFRESH=1; shift;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

cache_fresh() {
  [ -f "$CACHE" ] || return 1
  python3 - "$CACHE" <<'PY'
import json,sys,time
try:
    d=json.load(open(sys.argv[1]))
    t=time.mktime(time.strptime(d["testedAt"][:19],"%Y-%m-%dT%H:%M:%S"))
    sys.exit(0 if (time.time()-t)<86400 and d.get("ranked") else 1)
except Exception:
    sys.exit(1)
PY
}

test_one() {
  out=$(curl --noproxy '*' --max-time "$TIMEOUT" -sS -o /dev/null \
        -w '%{http_code} %{speed_download} %{size_download}' "${1}${URL}" 2>/dev/null)
  printf '%s\t%s\n' "$1" "$out"
}
export -f test_one
export URL TIMEOUT

if [ "$REFRESH" = "0" ] && cache_fresh; then
  python3 - "$CACHE" "$TOP" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for m in d.get("ranked",[])[:int(sys.argv[2])]:
    print(m)
PY
  exit 0
fi

RESULTS="$(mktemp)"
grep -v '^[[:space:]]*$' "$LIST" | xargs -r -P "$PARALLEL" -I{} bash -c 'test_one "$@"' _ {} > "$RESULTS"

python3 - "$RESULTS" "$CACHE" "$TOP" "$URL" <<'PY'
import sys,json,time
res,cache,top,url=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]
rows=[]
for line in open(res,encoding='utf-8',errors='ignore'):
    line=line.rstrip('\n')
    if not line: continue
    parts=line.split('\t')
    if len(parts)<2: continue
    m=parts[0]
    try:
        code,spd,size=parts[1].split()
        code=int(code); spd=float(spd); size=int(size)
    except Exception:
        continue
    if code==200 and size>200000:
        rows.append((spd,m))
rows.sort(reverse=True)
ranked=[m for _,m in rows]
json.dump({"testedAt":time.strftime("%Y-%m-%dT%H:%M:%S"),"testUrl":url,"ranked":ranked},open(cache,'w'))
for m in ranked[:top]:
    print(m)
PY
rm -f "$RESULTS"
