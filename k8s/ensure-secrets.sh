#!/bin/sh
# Create the per-namespace app secrets if they don't exist yet. Idempotent:
# existing secrets are never overwritten, so values survive redeploys.
# Values are random and live only in the cluster — never in git or GitHub.
#
#   usage: k8s/ensure-secrets.sh <namespace>        (KC overrides the kubectl command)
#
# Called by bin/start-local-k8s.sh (local) and by the K8s: Deploy workflow on the
# k3s node (staging/prod) before applying manifests.
# Stripe TEST keys for node-ecommerce are optional and added by hand:
#   kubectl -n <ns> create secret generic node-ecommerce-stripe \
#     --from-literal=stripe_API_KEY=sk_test_... --from-literal=STRIPE_PUBLISHABLE_KEY=pk_test_...
set -eu
ns="$1"
KC="${KC:-kubectl}"

$KC create namespace "$ns" --dry-run=client -o yaml | $KC apply -f - >/dev/null

rand() { head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 48; }

ensure() {
  name="$1"; shift
  if $KC -n "$ns" get secret "$name" >/dev/null 2>&1; then
    echo "secret $ns/$name exists"
  else
    $KC -n "$ns" create secret generic "$name" "$@" >/dev/null
    echo "secret $ns/$name created"
  fi
}

ensure node-ecommerce-secrets --from-literal=SESSION_SECRET="$(rand)"
ensure django-blog-secrets --from-literal=DJANGO_SECRET_KEY="$(rand)" --from-literal=POSTGRES_PASSWORD="$(rand)"
