#!/bin/bash
# =============================================================================
# incertotech — local Kubernetes bootstrap (minikube + kustomize)
# =============================================================================
# Side-by-side experiment: this does NOT touch the docker-compose setup.
#
# Usage (via make, which starts the cluster first with `make local-k8s-up`):
#   make local-k8s-start        # full run: cluster, images, deploy
#   make local-k8s-start-quick  # redeploy only (images already built)
# Run directly, the script expects the cluster to be running already.
#
# Prerequisites: docker (Desktop), minikube, kubectl, kustomize
# Optional:      mkcert (HTTPS with a locally-trusted cert)
#
# Every kubectl call passes --context so the global kubeconfig context is never
# relied on (other clusters in ~/.kube/config stay untouched).
# =============================================================================
set -euo pipefail

PROFILE="incertotech"
NAMESPACE="incertotech-local"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
APPS="$ROOT/portfolio"   # the four demo apps; the homepage stays at $ROOT/homepage
OVERLAY="$ROOT/k8s/overlays/local"
CERTS_DIR="$ROOT/k8s/certs"
KC="kubectl --context=$PROFILE"
SKIP_BUILD=false
for arg in "$@"; do case $arg in --skip-build) SKIP_BUILD=true ;; esac; done

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()   { echo -e "${BLUE}ℹ️  $1${NC}"; }
ok()     { echo -e "${GREEN}✅ $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail()   { echo -e "${RED}❌ $1${NC}"; exit 1; }
header() { echo ""; echo -e "${BLUE}══ $1 ══${NC}"; }

# ── 1. prerequisites ────────────────────────────────────────────────────────
header "1/7 Prerequisites"
for cmd in docker minikube kubectl kustomize; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd not found (brew install $cmd)"
  ok "$cmd"
done
docker info >/dev/null 2>&1 || fail "Docker is not running"
HAS_MKCERT=false; command -v mkcert >/dev/null 2>&1 && HAS_MKCERT=true
$HAS_MKCERT && ok "mkcert (HTTPS enabled)" || warn "mkcert not found — TLS secret will be skipped (brew install mkcert)"
[ -d "$ROOT/homepage" ] || fail "$ROOT/homepage not found — clone the homepage repo first"
for app in react-to-do react-electoral-map react-course-admin nest-blog-api node-ecommerce django-blog; do
  [ -d "$APPS/$app" ] || fail "$APPS/$app not found — clone the app repo into portfolio/ first (same as run-docker.dev.sh expects)"
done

# ── 2. cluster ──────────────────────────────────────────────────────────────
header "2/7 Minikube profile '$PROFILE' + Traefik"
if minikube status -p "$PROFILE" 2>/dev/null | grep -q "host: Running"; then
  ok "already running"
else
  # Starting lives in `make local-k8s-up` (one place, with --keep-context so the
  # global kubectl context is never switched).
  fail "minikube profile '$PROFILE' is not running — use make local-k8s-start (or make local-k8s-up)"
fi

# Traefik ingress controller (k8s/base/traefik). Replaces the minikube ingress
# addon, which is disabled if a previous run enabled it — both would claim
# :80/:443 through `minikube tunnel`.
if minikube addons list -p "$PROFILE" 2>/dev/null | grep "ingress " | grep -q enabled; then
  minikube addons disable ingress -p "$PROFILE" >/dev/null 2>&1 && ok "legacy ingress-nginx addon disabled"
fi
$KC apply --server-side --force-conflicts -k "$ROOT/k8s/base/traefik" >/dev/null
$KC -n traefik rollout status deploy/traefik --timeout=180s >/dev/null \
  && ok "traefik ready" || warn "traefik still starting"

# ── 3. namespace + TLS ──────────────────────────────────────────────────────
header "3/7 Namespace + TLS"
$KC create namespace "$NAMESPACE" --dry-run=client -o yaml | $KC apply -f - >/dev/null
ok "namespace $NAMESPACE"
if $HAS_MKCERT; then
  mkdir -p "$CERTS_DIR"
  if [ ! -f "$CERTS_DIR/incertotech.local.pem" ]; then
    mkcert -install >/dev/null 2>&1 || true
    mkcert -cert-file "$CERTS_DIR/incertotech.local.pem" -key-file "$CERTS_DIR/incertotech.local.key.pem" \
      incertotech.local "*.incertotech.local" >/dev/null 2>&1
    ok "mkcert certificate generated in k8s/certs/"
  else
    ok "certificate already exists"
  fi
  $KC create secret tls incertotech-tls -n "$NAMESPACE" \
    --cert="$CERTS_DIR/incertotech.local.pem" --key="$CERTS_DIR/incertotech.local.key.pem" \
    --dry-run=client -o yaml | $KC apply -f - >/dev/null
  ok "TLS secret incertotech-tls applied"
fi

# ── 4. images ───────────────────────────────────────────────────────────────
header "4/7 Images"
if $SKIP_BUILD; then
  info "skipping builds (--skip-build)"
else
  # shellcheck disable=SC1090
  set -a; source "$OVERLAY/build.env"; set +a

  # Same pre-build steps the per-app run-docker.dev.sh scripts do: React bakes
  # its API URL in at build time, and the homepage expands its links into
  # index.html. These generated files are gitignored in the app repos.
  printf "REACT_APP_TO_DO_SERVER_URL=%s" "$REACT_APP_TO_DO_SERVER_URL" > "$APPS/react-to-do/web/.env"
  printf "REACT_APP_COURSE_ADMIN_SERVER_URL=%s" "$REACT_APP_COURSE_ADMIN_SERVER_URL" > "$APPS/react-course-admin/web/.env"
  {
    for v in REACT_COURSE_ADMIN_URL REACT_ELECTORAL_MAP_URL REACT_TO_DO_URL NEST_TO_DO_API_URL NEST_BLOG_API_URL NEST_COURSE_ADMIN_API_URL NODE_ECOMMERCE_URL DJANGO_BLOG_URL; do
      echo "$v=${!v}"
    done
  } > "$ROOT/homepage/.env"
  ( cd "$ROOT/homepage" && bash expand-homepage-links.sh index-no-links.html index.html >/dev/null )
  ok "generated web/.env files and homepage/index.html for *.incertotech.local"

  # Build inside minikube's docker daemon so pods can use the images with
  # imagePullPolicy: Never. The context is streamed as a tar with node_modules
  # excluded — the app repos have no .dockerignore, and host node_modules would
  # otherwise be uploaded and copied over the image's own `npm install`.
  eval "$(minikube -p "$PROFILE" docker-env)"
  build_image() {  # name  context-dir  dockerfile-relative-to-context
    local name=$1 ctx=$2 df=$3
    info "building $name:local  ($ctx / $df)"
    tar -C "$ctx" --exclude='node_modules' --exclude='.git' --exclude='*.md' --exclude='.env' -cf - . \
      | docker build -q -f "$df" -t "$name:local" - >/dev/null
    ok "$name:local"
  }
  build_image homepage                     "$ROOT/homepage"                   Dockerfile
  build_image react-electoral-map          "$APPS/react-electoral-map"        Dockerfile
  build_image react-to-do_postgres         "$APPS/react-to-do/server"         docker/postgres/Dockerfile
  build_image react-to-do_server           "$APPS/react-to-do/server"         docker/server/Dockerfile
  build_image react-to-do_web              "$APPS/react-to-do/web"            docker/Dockerfile
  build_image react-course-admin_postgres  "$APPS/react-course-admin/server"  docker/postgres/Dockerfile
  build_image react-course-admin_server    "$APPS/react-course-admin/server"  docker/server/Dockerfile
  build_image react-course-admin_web       "$APPS/react-course-admin/web"     docker/Dockerfile
  build_image nest-blog-api_postgres       "$APPS/nest-blog-api"              docker/postgres/Dockerfile
  build_image nest-blog-api_server         "$APPS/nest-blog-api"              docker/server/Dockerfile
  build_image node-ecommerce               "$APPS/node-ecommerce/web"         Dockerfile
  build_image django-blog                  "$APPS/django-blog/web"            Dockerfile
  eval "$(minikube -p "$PROFILE" docker-env --unset)"
  ok "all images built"
fi

# ── 5. deploy ───────────────────────────────────────────────────────────────
header "5/7 Deploy (kustomize overlays/local)"
$KC apply --server-side --force-conflicts -k "$OVERLAY" >/dev/null
ok "manifests applied"
# Images are rebuilt under the same :local tags, which Kubernetes can't detect as
# a change, so restart the deployments to pick up freshly built images.
if ! $SKIP_BUILD; then
  $KC -n "$NAMESPACE" rollout restart deployment >/dev/null && ok "deployments restarted onto the new images"
fi
$KC -n "$NAMESPACE" delete ingress --all --ignore-not-found >/dev/null 2>&1 || true   # prune ingress-nginx-era objects
info "waiting for deployments..."
$KC -n "$NAMESPACE" wait --for=condition=available deployment --all --timeout=300s >/dev/null \
  && ok "all deployments available" || warn "some deployments not ready yet — check: make local-k8s-status"

# ── 6. status ───────────────────────────────────────────────────────────────
header "6/7 Pods"
$KC -n "$NAMESPACE" get pods

# ── 7. host access ──────────────────────────────────────────────────────────
header "7/7 Reaching it from your browser"
HOSTS="incertotech.local react-to-do.incertotech.local react-electoral-map.incertotech.local react-course-admin.incertotech.local nest-to-do-api.incertotech.local nest-blog-api.incertotech.local nest-course-admin-api.incertotech.local"
if grep -q "incertotech.local" /etc/hosts 2>/dev/null; then
  ok "/etc/hosts already has incertotech.local entries"
else
  warn "add the hostnames to /etc/hosts (one-time):"
  echo "    sudo sh -c 'echo \"127.0.0.1 $HOSTS\" >> /etc/hosts'"
fi
echo ""
echo "  Then, in a separate terminal (needs sudo, keeps running):"
echo "    make local-k8s-tunnel   # sudo minikube tunnel -p $PROFILE"
echo ""
echo "  URLs:"
for h in $HOSTS; do echo "    https://$h"; done
echo ""
echo "  No sudo? Port-forward Traefik instead and use the :8443 URLs:"
echo "    make local-k8s-forward     # then https://incertotech.local:8443 etc."
