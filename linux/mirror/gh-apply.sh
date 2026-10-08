#!/bin/bash
# =============================================================================
#  github-watchdog (linux) :: mirror :: gh-apply.sh
#  Make git downloads (clone/fetch/pull) from github.com use the fastest working
#  third-party mirror, while push stays on the real github.com.
#
#  Modes:
#    (default)/--apply   pick fastest (24h cache else full test) + apply
#    --refresh           force full re-test, then apply
#    --auto              quick per-use refresh: re-test only current top
#                        candidates and switch if a faster one appears (debounced)
#    --status            show current setting
#    --off               remove everything -> git goes direct again
#
#  Options:
#    --include-ssh       also rewrite git@github.com: / ssh:// / git:// forms
#                        (default: OFF -> SSH stays direct for private repos)
#    --quick N           candidates re-tested in --auto (default 6)
#    --quick-timeout S   seconds per candidate in --auto (default 4)
#    --debounce MIN      min gap between --auto runs (default 3)
#
#  git config written (scope = --global by default):
#    url."<mirror>https://github.com/".insteadOf  = https://github.com/
#    url."https://github.com/".pushInsteadOf      = https://github.com/   (push direct)
#    credential."https://<mirror-host>".helper = ""   (no prompt)
#    http."https://<mirror-host>".proxy = ""          (bypass local mitmproxy)
# =============================================================================
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TESTER="$HERE/gh-fastest.sh"
CACHE="$HERE/mirrors-ranked.json"
STATE="$HERE/applied.json"
LOCK="$HERE/auto.lock"
TEST_URL="https://github.com/cli/cli/archive/refs/heads/trunk.zip"
PLAIN="https://github.com/"
SCOPE="--global"

MODE="apply"
QUICK=6
QUICK_TIMEOUT=4
DEBOUNCE_MIN=3
INCLUDE_SSH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)          MODE="apply";;
    --refresh)        MODE="refresh";;
    --auto)           MODE="auto";;
    --status)         MODE="status";;
    --off)            MODE="off";;
    --include-ssh)    INCLUDE_SSH=1;;
    --quick)          QUICK="${2:-6}"; shift;;
    --quick-timeout)  QUICK_TIMEOUT="${2:-4}"; shift;;
    --debounce)       DEBOUNCE_MIN="${2:-3}"; shift;;
    -h|--help)        sed -n '2,24p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
  shift
done

gitc() { git config "$SCOPE" "$@"; }

patterns() {
  echo "$PLAIN"
  if [ "$INCLUDE_SSH" = "1" ]; then
    echo "git@github.com:"
    echo "ssh://git@github.com/"
    echo "git://github.com/"
  fi
}

cleanup_legacy_system() {
  # remove the old hardcoded single-source keys written to the system scope
  git config --system --unset-all "url.https://gh-proxy.com/https://github.com/.insteadOf" 2>/dev/null
  git config --system --unset-all "url.https://gh-proxy.com/https://github.com/.insteadof" 2>/dev/null
  git config --system --unset-all "url.https://github.com/.pushInsteadOf" 2>/dev/null
  git config --system --unset-all "url.https://github.com/.pushinsteadOf" 2>/dev/null
}

undo_applied() {
  if [ -f "$STATE" ]; then
    base=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("base",""))' "$STATE" 2>/dev/null)
    cred=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("credKey",""))' "$STATE" 2>/dev/null)
    proxy=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("proxyKey",""))' "$STATE" 2>/dev/null)
    [ -n "$base" ] && gitc --unset-all "url.$base.insteadOf" 2>/dev/null
    gitc --unset-all "url.$PLAIN.pushInsteadOf" 2>/dev/null
    [ -n "$cred" ]  && gitc --unset-all "$cred" 2>/dev/null
    [ -n "$proxy" ] && gitc --unset-all "$proxy" 2>/dev/null
  else
    gitc --unset-all "url.$PLAIN.pushInsteadOf" 2>/dev/null
  fi
  rm -f "$STATE"
}

apply_mirror() {
  fastest="$1"
  base="${fastest}https://github.com/"
  mhost=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).hostname or "")' "$fastest")
  credkey="credential.https://$mhost.helper"
  proxykey="http.https://$mhost.proxy"

  undo_applied
  cleanup_legacy_system

  for p in $(patterns); do
    gitc --add "url.$base.insteadOf" "$p"
    gitc --add "url.$PLAIN.pushInsteadOf" "$p"
  done
  gitc --replace-all "$credkey" ""
  gitc --replace-all "$proxykey" ""

  python3 - "$STATE" "$fastest" "$base" "$credkey" "$proxykey" <<'PY'
import json,sys,time
json.dump({"mirror":sys.argv[2],"base":sys.argv[3],"credKey":sys.argv[4],
           "proxyKey":sys.argv[5],"appliedAt":time.strftime("%Y-%m-%dT%H:%M:%S")},
          open(sys.argv[1],"w"))
PY
  echo "Applied fastest mirror : $fastest"
  echo "  clone/fetch/pull (https) ->  $base"
  echo "  push (https)             ->  $PLAIN (direct)"
  echo "  mirror credential + proxy -> disabled (direct, no prompt)"
  [ "$INCLUDE_SSH" = "0" ] && echo "  (SSH forms untouched -> private repos stay on SSH)"
}

get_fastest() {
  force="$1"
  if [ "$force" != "1" ] && [ -f "$CACHE" ]; then
    f=$(python3 -c '
import json,sys,time
try:
    d=json.load(open(sys.argv[1]))
    t=time.mktime(time.strptime(d["testedAt"][:19],"%Y-%m-%dT%H:%M:%S"))
    if (time.time()-t)<86400 and d.get("ranked"):
        print(d["ranked"][0])
except Exception: pass
' "$CACHE")
    [ -n "$f" ] && { echo "$f"; return; }
  fi
  bash "$TESTER" --refresh --top 1
}

test_candidates() {
  best=""; bestspd=0
  for m in "$@"; do
    read -r code spd size <<< "$(curl --noproxy '*' --max-time "$QUICK_TIMEOUT" -sS -o /dev/null \
        -w '%{http_code} %{speed_download} %{size_download}' "${m}${TEST_URL}" 2>/dev/null)"
    if [ "${code:-}" = "200" ] && [ "${size:-0}" -gt 200000 ] 2>/dev/null; then
      if python3 -c "import sys;sys.exit(0 if float('${spd:-0}')>float('${bestspd:-0}') else 1)" 2>/dev/null; then
        best="$m"; bestspd="$spd"
      fi
    fi
  done
  [ -n "$best" ] && echo "$best"
}

case "$MODE" in
  status)
    if [ -f "$STATE" ]; then
      python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("Active mirror :",d.get("mirror",""));print("applied at    :",d.get("appliedAt",""))' "$STATE"
    else
      echo "No mirror applied (git goes direct)."
    fi
    ;;
  off)
    undo_applied
    echo "Mirror rewrite removed; git now goes direct."
    ;;
  auto)
    if [ -f "$LOCK" ]; then
      age=$(python3 -c 'import os,sys,time;print((time.time()-os.path.getmtime(sys.argv[1]))/60.0)' "$LOCK")
      if python3 -c "import sys;sys.exit(0 if float('${age:-999}')<float('${DEBOUNCE_MIN}') else 1)" 2>/dev/null; then exit 0; fi
    fi
    date +%Y-%m-%dT%H:%M:%S > "$LOCK"
    ranked=""
    [ -f "$CACHE" ] && ranked=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("\n".join(d.get("ranked",[])[:int(sys.argv[2])]))' "$CACHE" "$QUICK")
    if [ -z "$ranked" ]; then
      fastest=$(get_fastest 1)
    else
      fastest=$(test_candidates $ranked)
    fi
    [ -z "$fastest" ] && exit 0
    cur=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("mirror",""))' "$STATE" 2>/dev/null || echo "")
    if [ "$cur" != "$fastest" ]; then apply_mirror "$fastest"; fi
    ;;
  refresh)
    fastest=$(get_fastest 1)
    [ -z "$fastest" ] && { echo "no working mirror found (all timed out)" >&2; exit 1; }
    apply_mirror "$fastest"
    ;;
  apply)
    fastest=$(get_fastest 0)
    [ -z "$fastest" ] && { echo "no working mirror found (all timed out)" >&2; exit 1; }
    apply_mirror "$fastest"
    ;;
esac
