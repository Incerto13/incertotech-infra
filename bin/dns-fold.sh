#!/usr/bin/env bash
# Fold one delegated sub-zone of incertotech.com into the apex zone.
#
#   bin/dns-fold.sh <sub-zone>            dry run: print the change batch
#   bin/dns-fold.sh <sub-zone> --apply    submit it, wait, verify
#   bin/dns-fold.sh <sub-zone> --delete   delete the (already folded) sub-zone
#
# Folding = ONE Route53 change batch on the apex that deletes the NS delegation
# for <sub-zone> and creates a copy of every record the sub-zone serves (all
# but its own SOA/NS — NS delegations to deeper zones ARE copied, so folding
# staging.incertotech.com keeps react-to-do.staging.* etc. delegated until they
# are folded in turn). Route53 applies a batch atomically, so there is no
# moment where the name resolves to nothing.
#
# The sub-zone is left in place, unchanged: resolvers may have cached its
# nameservers (its NS TTL is 172800s = 2 days) and keep asking it, and it still
# gives the same answers. --delete refuses until 48h after the fold, which is
# recorded in terraform/dns/fold-log.txt.
#
# Only the apex is ever a target: a sub-zone whose delegation lives in another
# sub-zone (e.g. react-to-do.staging.* before staging.* is folded) is refused.
set -euo pipefail

APEX="incertotech.com."
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/terraform/dns/fold-log.txt"
export AWS_PROFILE="${AWS_PROFILE:-incertotech-infra}"

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 <sub-zone> [--apply|--delete]"
SUB="${1%.}."
MODE="${2:-dry-run}"
case "$MODE" in dry-run|--apply|--delete) ;; *) die "unknown mode $MODE" ;; esac
[[ "$SUB" == *".$APEX" ]] || die "$SUB is not under $APEX"

zone_id() {
  local ids
  ids=$(aws route53 list-hosted-zones-by-name --dns-name "$1" --output json \
    | jq -r --arg n "$1" '[.HostedZones[] | select(.Name == $n and (.Config.PrivateZone | not)) | .Id | sub("/hostedzone/"; "")] | join(" ")')
  [ -n "$ids" ] || return 1
  [ "$(wc -w <<<"$ids")" -eq 1 ] || die "more than one public zone named $1: $ids"
  echo "$ids"
}

APEX_ID=$(zone_id "$APEX") || die "apex zone $APEX not found"
APEX_NS=$(aws route53 get-hosted-zone --id "$APEX_ID" --query 'DelegationSet.NameServers[0]' --output text)

# ───────────────────────────── delete ─────────────────────────────
if [ "$MODE" = "--delete" ]; then
  SUB_ID=$(zone_id "$SUB") || die "$SUB has no hosted zone (already deleted?)"
  aws route53 list-resource-record-sets --hosted-zone-id "$APEX_ID" \
    --query "ResourceRecordSets[?Name=='$SUB' && Type=='NS']" --output json | jq -e 'length == 0' >/dev/null \
    || die "$APEX still delegates $SUB — fold it first"
  folded_at=$(grep -E "^[^ ]+ fold $SUB " "$LOG" 2>/dev/null | tail -1 | cut -d' ' -f1 || true)
  [ -n "$folded_at" ] || die "no fold of $SUB recorded in $LOG"
  age=$(( $(date -u +%s) - $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$folded_at" +%s) ))
  [ "$age" -ge 172800 ] || die "$SUB was folded at $folded_at; wait until 48h after that (resolvers may still cache its nameservers)"

  # Route53 only deletes an empty zone: remove everything but its SOA/NS first.
  batch=$(aws route53 list-resource-record-sets --hosted-zone-id "$SUB_ID" --output json | jq --arg sub "$SUB" '
    {Changes: [.ResourceRecordSets[]
      | select(.Type != "SOA" and (.Type != "NS" or .Name != $sub))
      | {Action: "DELETE", ResourceRecordSet: .}]}')
  echo "$batch" | jq .
  read -r -p "Delete hosted zone $SUB ($SUB_ID) and the records above? [y/N] " ok
  [ "$ok" = y ] || die "aborted"
  if [ "$(jq '.Changes | length' <<<"$batch")" -gt 0 ]; then
    aws route53 change-resource-record-sets --hosted-zone-id "$SUB_ID" --change-batch "$batch" >/dev/null
  fi
  aws route53 delete-hosted-zone --id "$SUB_ID" >/dev/null
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) delete $SUB $SUB_ID" >> "$LOG"
  echo "deleted $SUB"
  exit 0
fi

# ───────────────────────────── fold ─────────────────────────────
SUB_ID=$(zone_id "$SUB") || die "$SUB has no hosted zone"

delegation=$(aws route53 list-resource-record-sets --hosted-zone-id "$APEX_ID" --output json \
  | jq --arg sub "$SUB" '[.ResourceRecordSets[] | select(.Name == $sub and .Type == "NS")]')
[ "$(jq length <<<"$delegation")" -eq 1 ] \
  || die "$APEX has no NS delegation for $SUB (already folded, or delegated from another sub-zone — fold that one first)"

records=$(aws route53 list-resource-record-sets --hosted-zone-id "$SUB_ID" --output json \
  | jq --arg sub "$SUB" '[.ResourceRecordSets[] | select(.Type != "SOA" and (.Type != "NS" or .Name != $sub))]')

# The apex must not already hold any of these names (it would shadow or clash).
clash=$(aws route53 list-resource-record-sets --hosted-zone-id "$APEX_ID" --output json \
  | jq --argjson r "$records" --arg sub "$SUB" '
      [.ResourceRecordSets[] | select(.Name as $n | $r | any(.Name == $n))
                             | select((.Type == "NS" and .Name == $sub) | not)
                             | "\(.Name) \(.Type)"]')
[ "$(jq length <<<"$clash")" -eq 0 ] || die "apex already has records at these names: $(jq -c . <<<"$clash")"

batch=$(jq -n --argjson d "$delegation" --argjson r "$records" --arg sub "$SUB" '{
  Comment: "fold \($sub) into the apex",
  Changes: ([{Action: "DELETE", ResourceRecordSet: $d[0]}] + [$r[] | {Action: "CREATE", ResourceRecordSet: .}])
}')

echo "== $SUB ($SUB_ID) -> $APEX ($APEX_ID)"
jq -r '.Changes[] | "  \(.Action)\t\(.ResourceRecordSet.Name)\t\(.ResourceRecordSet.Type)\t\(
  if .ResourceRecordSet.AliasTarget then "ALIAS \(.ResourceRecordSet.AliasTarget.DNSName)"
  else ([.ResourceRecordSet.ResourceRecords[].Value] | join(",")) end)"' <<<"$batch"

if [ "$MODE" = "dry-run" ]; then
  echo "(dry run — re-run with --apply to submit)"
  exit 0
fi

change=$(aws route53 change-resource-record-sets --hosted-zone-id "$APEX_ID" --change-batch "$batch" \
  --query ChangeInfo.Id --output text)
echo "submitted $change, waiting for INSYNC..."
aws route53 wait resource-record-sets-changed --id "$change"
mkdir -p "$(dirname "$LOG")"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) fold $SUB $SUB_ID" >> "$LOG"

# Verify straight against an apex nameserver: no referral any more, and every
# copied record answers the same as it does from the sub-zone.
SUB_NS=$(aws route53 get-hosted-zone --id "$SUB_ID" --query 'DelegationSet.NameServers[0]' --output text)
fail=0
if dig +norec +noall +authority "$SUB" @"$APEX_NS" | grep -qw NS; then
  echo "FAIL  $APEX_NS still refers $SUB elsewhere"; fail=1
fi
while read -r name type; do
  a=$(dig +short +norec "$name" "$type" @"$APEX_NS" | sort)
  b=$(dig +short +norec "$name" "$type" @"$SUB_NS" | sort)
  if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "ok    $name $type"; else echo "FAIL  $name $type apex=[$a] sub=[$b]"; fail=1; fi
done < <(jq -r '.[] | select(.Type != "NS") | "\(.Name) \(.Type)"' <<<"$records")
[ "$fail" -eq 0 ] || die "verification failed — the sub-zone is untouched; compare and fix the apex records by hand"
echo "folded $SUB. Leave its zone in place for 48h, then: $0 $SUB --delete"
