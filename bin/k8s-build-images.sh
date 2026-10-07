#!/usr/bin/env bash
# Build and push every app image for one environment, then pin the overlay to
# the exact tags. Run by .github/workflows/k8s-deploy.yml before it renders the
# manifests (the techneip deploy works the same way: the deploy builds).
#
#   bin/k8s-build-images.sh <staging|prod> <workdir>
#
# 1. clones each app repo at the environment's branch (staging -> staging,
#    prod -> main) into <workdir>
# 2. writes the build-time files from k8s/overlays/<env>/build.env (React API
#    URLs, the homepage's expanded links) — same recipe as
#    bin/start-local-k8s.sh, which builds the :local images
# 3. builds each image for linux/amd64 and pushes it as <env>-<app commit sha>
#    (immutable; what the cluster runs). It deliberately does NOT push
#    <env>-latest: the live docker-compose deployment pulls those tags (built
#    by each app repo's own CI) and must not get these builds. Layer cache
#    lives in a :buildcache tag per image, so rebuilding an unchanged app is
#    quick.
# 4. `kustomize edit set image` in the overlay, so the rendered manifests use
#    the immutable tags. Changed tags = changed pod specs, so every deploy rolls
#    the pods that actually changed — no `rollout restart` needed.
#
# Needs: docker buildx, a `docker login` as incerto13, git, kustomize.
set -euo pipefail

ENV="${1:?usage: $0 <staging|prod> <workdir>}"
WORK="${2:?usage: $0 <staging|prod> <workdir>}"
case "$ENV" in
  staging) BRANCH=staging ;;
  prod)    BRANCH=main ;;
  *) echo "unknown env $ENV" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/k8s/overlays/$ENV"
REGISTRY=incerto13

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

# ── 1. sources ──────────────────────────────────────────────────────────────
declare -A SHA
for repo in homepage react-to-do react-electoral-map react-course-admin nest-blog-api node-ecommerce django-blog; do
  rm -rf "${WORK:?}/$repo"
  git clone --quiet --depth 1 --branch "$BRANCH" "https://github.com/Incerto13/$repo.git" "$WORK/$repo"
  SHA[$repo]=$(git -C "$WORK/$repo" rev-parse --short=7 HEAD)
  echo "$repo@$BRANCH ${SHA[$repo]}"
done

# ── 2. build-time files ─────────────────────────────────────────────────────
set -a
# shellcheck disable=SC1091
source "$OVERLAY/build.env"
set +a
printf "REACT_APP_TO_DO_SERVER_URL=%s" "$REACT_APP_TO_DO_SERVER_URL" > "$WORK/react-to-do/web/.env"
printf "REACT_APP_COURSE_ADMIN_SERVER_URL=%s" "$REACT_APP_COURSE_ADMIN_SERVER_URL" > "$WORK/react-course-admin/web/.env"
for v in REACT_COURSE_ADMIN_URL REACT_ELECTORAL_MAP_URL REACT_TO_DO_URL NEST_TO_DO_API_URL NEST_BLOG_API_URL NEST_COURSE_ADMIN_API_URL NODE_ECOMMERCE_URL DJANGO_BLOG_URL; do
  echo "$v=${!v}"
done > "$WORK/homepage/.env"
( cd "$WORK/homepage" && bash expand-homepage-links.sh index-no-links.html index.html >/dev/null )

# ── 3. build + push ─────────────────────────────────────────────────────────
#        image                        repo                context (in repo)  dockerfile (in context)
IMAGES=(
  "homepage                     homepage            .        Dockerfile"
  "react-electoral-map          react-electoral-map .        Dockerfile"
  "react-to-do_postgres         react-to-do         server   docker/postgres/Dockerfile"
  "react-to-do_server           react-to-do         server   docker/server/Dockerfile"
  "react-to-do_web              react-to-do         web      docker/Dockerfile"
  "react-course-admin_postgres  react-course-admin  server   docker/postgres/Dockerfile"
  "react-course-admin_server    react-course-admin  server   docker/server/Dockerfile"
  "react-course-admin_web       react-course-admin  web      docker/Dockerfile"
  "nest-blog-api_postgres       nest-blog-api       .        docker/postgres/Dockerfile"
  "nest-blog-api_server         nest-blog-api       .        docker/server/Dockerfile"
  "node-ecommerce               node-ecommerce      web      Dockerfile"
  "django-blog                  django-blog         web      Dockerfile"
)

cd "$OVERLAY"
for line in "${IMAGES[@]}"; do
  read -r image repo ctx df <<<"$line"
  tag="$ENV-${SHA[$repo]}"
  echo "::group::$REGISTRY/$image:$tag"
  docker buildx build --platform linux/amd64 --push \
    --cache-from "type=registry,ref=$REGISTRY/$image:buildcache" \
    --cache-to "type=registry,ref=$REGISTRY/$image:buildcache,mode=max" \
    -f "$WORK/$repo/$ctx/$df" \
    -t "$REGISTRY/$image:$tag" \
    "$WORK/$repo/$ctx"
  echo "::endgroup::"
  # ── 4. pin the overlay to the immutable tag ──
  kustomize edit set image "$image=$REGISTRY/$image:$tag"
done

echo "pinned images in $OVERLAY/kustomization.yaml:"
sed -n '/^images:/,/^[a-z]/p' kustomization.yaml | grep -E 'newName|newTag' | paste - - | awk '{print "  " $2 ":" $4}'
