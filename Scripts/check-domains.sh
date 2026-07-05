#!/usr/bin/env bash
# check-domains.sh — bulk domain-availability checker (RDAP + whois), built for name-brainstorming.
#
# Usage:
#   ./Scripts/check-domains.sh names.txt                 # one name per line; default TLDs: com ai app io
#   ./Scripts/check-domains.sh -t "com ai" names.txt
#   printf 'foo\nbar\n' | ./Scripts/check-domains.sh -   # names on stdin
#   ./Scripts/check-domains.sh -t com foo bar baz        # names as args
#
# Method per TLD (chosen for reliability — plain rdap.org gets rate-limited and returns unfollowed
# redirects): .com/.net via Verisign RDAP; .ai via `whois whois.nic.ai` (no reliable RDAP); everything
# else via the IANA RDAP bootstrap (rdap.org, following redirects) with retry/backoff on 429/timeouts.
# 404 = AVAILABLE, 200 = taken, anything else = unknown (recheck). Results cache to $TMPDIR so repeat
# runs and re-crank iterations are instant.
#
# Prints a per-domain table, then an "AVAILABLE, grouped by name" summary.
set -uo pipefail

CACHE="${TMPDIR:-/tmp}/domcheck-cache"
mkdir -p "$CACHE"

# ---- single-domain mode (used by the parallel fan-out; also handy standalone) ------------------------
if [ "${1:-}" = "--one" ]; then
  domain="$2"
  tld="${domain##*.}"
  cf="$CACHE/$domain"
  if [ -f "$cf" ]; then printf '%s\t%s\n' "$(cat "$cf")" "$domain"; exit 0; fi

  code=""
  case "$tld" in
    com|net)
      for i in 1 2 3; do
        code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 8 \
               "https://rdap.verisign.com/$tld/v1/domain/$domain" 2>/dev/null)
        case "$code" in 200|404) break;; esac
        sleep $((i*i))
      done
      ;;
    ai|io)
      # whois (no reliable RDAP). NOTE: the registry prints boilerplate about the TLD itself before the
      # result, so match the actual-record signals, not generic words like "nserver"/"status". whois.nic
      # throttles concurrent queries (empty reply), so retry on an ambiguous/empty response.
      code=000
      for i in 1 2 3; do
        out=$(whois "$domain" 2>/dev/null)
        if printf '%s' "$out" | grep -qiE 'domain not found|not registered|no match|no object found|is available for|is available|no data found'; then
          code=404; break
        elif printf '%s' "$out" | grep -qiE 'domain name:|registry expiry date|registry domain id|creation date|registrant'; then
          code=200; break
        fi
        sleep $((i*i))
      done
      ;;
    *)
      for i in 1 2 3; do
        code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 9 \
               "https://rdap.org/domain/$domain" 2>/dev/null)
        case "$code" in 200|404) break;; esac
        sleep $((i*i))
      done
      ;;
  esac

  case "$code" in
    404) status="AVAILABLE";;
    200) status="taken";;
    *)   status="unknown($code)";;
  esac
  # Only cache definitive answers, so transient failures get retried next run.
  case "$status" in AVAILABLE|taken) printf '%s' "$status" > "$cf";; esac
  printf '%s\t%s\n' "$status" "$domain"
  exit 0
fi

# ---- main mode --------------------------------------------------------------------------------------
TLDS="com ai app io"
JOBS=5
NAMES=()

while [ $# -gt 0 ]; do
  case "$1" in
    -t) TLDS="$2"; shift 2;;
    -j) JOBS="$2"; shift 2;;
    -)  while IFS= read -r line; do [ -n "$line" ] && NAMES+=("$line"); done; shift;;
    -*) echo "unknown flag: $1" >&2; exit 2;;
    *)
      if [ -f "$1" ]; then
        while IFS= read -r line; do
          line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
          [ -n "$line" ] && NAMES+=("$line")
        done < "$1"
      else
        NAMES+=("$1")
      fi
      shift;;
  esac
done

if [ "${#NAMES[@]}" -eq 0 ]; then echo "no names given" >&2; exit 2; fi

self="$0"
domains=()
for n in "${NAMES[@]}"; do
  n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')
  for t in $TLDS; do domains+=("$n.$t"); done
done

results=$(printf '%s\n' "${domains[@]}" | xargs -P "$JOBS" -I{} "$self" --one {})

echo "=== all results ==="
printf '%s\n' "$results" | sort

echo ""
echo "=== AVAILABLE (grouped by name) ==="
printf '%s\n' "$results" | awk -F'\t' '$1=="AVAILABLE"{print $2}' \
  | awk -F. '{n=$1; t=$2; a[n]=a[n]" ."t} END{for(k in a) printf "  %-16s%s\n", k, a[k]}' \
  | sort
