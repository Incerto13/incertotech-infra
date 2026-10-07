# Kubernetes experiment — working context

Handoff notes for anyone (human or agent) continuing the Kubernetes work in this
repo. Written 2026-10-03 at the end of the session that created `k8s/`.
Repo was renamed from `incertotech-k8` to `incertotech-infra` during that session.

## 1. What this repo is

The "orchestration" repo for incertotech.com. It runs the homepage and five demo
apps in containers on one EC2 instance per environment (staging, prod).

**The apps are separate git repos cloned into gitignored subdirectories:**
`homepage/` at the repo root, and the four demo apps under `portfolio/`:
`react-to-do/`, `react-electoral-map/`, `react-course-admin/`, `nest-blog-api/`
(moved there 2026-10-03; `bin/start-local-k8s.sh` and `run-docker.dev.sh`
resolve them via that prefix). Changing anything inside them is a change to
another repo.

### Current production setup (unchanged, still the real deployment)

- `docker-compose.yml` pulls prebuilt images `incerto13/<name>:${ENV}-latest`
  from Docker Hub. Every container publishes a host port, including the three
  Postgres instances (5433, 5434, 5435).
- `nginx-proxy` (plain `nginx:latest`) owns ports 80/443 and mounts
  `nginx/default.conf-${ENV}`. One `server` block per subdomain. Port 80 is a
  301 to HTTPS. One Let's Encrypt SAN cert covers every hostname, obtained via
  `docker-compose.ssl.yml` + `run-certbot-init.sh` (webroot challenge).
- Quirk: frontends are proxied by container name over the compose network
  (`http://homepage`, `http://react-to-do_web`), but API paths are proxied back
  out through the **public hostname and host-published port**
  (`react-to-do.incertotech.com:8110/api`, `incertotech.com:8112/graphql`).
  That only works because those ports are open on the host/security group, and
  it means the servers are reachable over plain HTTP, bypassing nginx.
- `nginx/`, `.env`, `certbot/` are gitignored. GitHub Actions
  (`.github/workflows/*-cicd.yml`, manual trigger only) SSH into the EC2 host,
  write `.env` and the nginx conf from repository secrets, `git pull`, pull
  images, and run `run-docker.sh` (compose up --force-recreate).
  **The workflows `cd incertotech-k8` on the server** — that is the clone
  directory name on EC2, unaffected by the local rename, but if the GitHub repo
  itself is renamed those lines and the remote clones need updating.
- Local dev (`run-docker.dev.sh`) runs each app's own `docker-compose.dev.yml`,
  no proxy, homepage on :8080.

### App internals that matter for k8s

| app | tiers | ports | notes |
|---|---|---|---|
| homepage | static nginx | 80 | links expanded into `index.html` at **build time** by `expand-homepage-links.sh` from `homepage/.env` |
| react-to-do | web (nginx:alpine) + server (Nest, :3001, global prefix `/api`, Swagger at `/docs`) + postgres (:5433, db `react-to-do`) | 80 / 3001 / 5433 | web bakes `REACT_APP_TO_DO_SERVER_URL` at build time from `web/.env` |
| react-course-admin | same shape | 80 / 3001 / 5434 | `REACT_APP_COURSE_ADMIN_SERVER_URL`, db `react-course-admin` |
| react-electoral-map | static nginx | 80 | no backend |
| nest-blog-api | server (Nest, :3001, GraphQL at `/graphql`, Swagger at `/rest`) + postgres (:5435, db `nest-blog`) | 3001 / 5435 | no web tier |

- Servers read only `<PREFIX>_TYPEORM_HOST` and `<PREFIX>_POSTGRES_PORT` from
  env; user/password/db name are hard-coded (`postgres`/`postgres`).
- Postgres images bake in `docker/postgres/postgresql.conf` (custom port,
  `listen_addresses='*'`) and `seed.sql` (runs once on an empty data dir).
- **Each Nest server has a hard-coded CORS whitelist** of the real
  `*.incertotech.com` hostnames in `server/src/main.ts`. Unknown origins get a
  500 "Not allowed by CORS". Browsers send `Origin` on every non-GET request,
  even same-origin, so any new hostname breaks POST/PUT/DELETE unless either
  the whitelist is edited (app repo change) or the proxy strips `Origin`.
- `nest-to-do-api.*` and `nest-course-admin-api.*` are not separate apps; they
  point at the react-to-do / react-course-admin server Swagger pages.

## 2. The Kubernetes experiment (`k8s/`, `bin/`, Makefile)

Goal stated by the user: try Kubernetes **side by side** with the compose
setup, copying the kustomize base + overlays pattern from
`/Users/hezekiah/dev/Projects_Clients/techneip_project/techneip-infra/k8s`,
and get it running locally first. **Do not change the compose deployment.**

```
k8s/
  base/<app>/<app>.yaml      ONE Deployment + ONE Service per app (multi-container
                             pod: postgres sidecar + server + web), PVC per postgres
  base/kustomization.yaml    bare image names (react-to-do_web etc.)
  base/traefik/, traefik-crds/  Traefik v3.7.9 controller + CRDs (applied standalone)
  overlays/local/            ns incertotech-local, :local tags, pullPolicy Never,
                             ingressroute.yaml + traefik-middlewares.yaml, build.env
  overlays/staging/, prod/   scaffolds: incerto13/*:<env>-latest, real hostnames,
                             pullPolicy Always, IngressRoute on plain HTTP (TLS at
                             the ALB). Render but deploy nowhere.
  certs/                     mkcert output (gitignored)
  README.md                  compose -> k8s mapping, how-to, rationale
bin/start-local-k8s.sh       cluster -> traefik -> TLS -> build 10 images -> apply
Makefile                     local-k8s-* targets (all use --context=incertotech)
```

Design decisions, with reasons:

- **Service names use dashes** (`react-to-do-web`), image names keep the
  underscore (`react-to-do_web`) to match Docker Hub repo names. Kubernetes DNS
  labels cannot contain `_`.
- **Images are built locally into minikube's docker daemon** (not pulled from
  Hub) because the web bundles and homepage bake URLs in at build time. The
  prebuilt Hub images point at staging/prod APIs. Build contexts are streamed
  as `tar --exclude=node_modules` because the app repos (except the React
  `web/` dirs and electoral-map) have no `.dockerignore`.
- The bootstrap regenerates `homepage/.env`, `homepage/index.html`,
  `portfolio/react-to-do/web/.env`, `portfolio/react-course-admin/web/.env` from
  `k8s/overlays/local/build.env`, exactly like the existing
  `run-docker.dev.sh` scripts do. Those files are gitignored in the app repos,
  and the compose dev scripts overwrite them again.
- **Postgres PVCs mount at `/var/lib/postgresql`** (parent dir) so the layout
  works for both postgres 16/17 (`.../data`) and 18 (`.../18/docker`).
  `postgres:latest` at build time was 18. StorageClass is left unset so the
  cluster default is used (minikube `standard`; on EKS this needs the EBS CSI
  driver or pods stay Pending).
- **One pod per app (user rule, 2026-10-04):** "each app i.e. react-to-do
  will utilize exactly one pod at the most, even if it has multiple
  microservices like postgres, servers, frontend". Postgres is a *native
  sidecar* initContainer (`restartPolicy: Always`, `pg_isready` startupProbe,
  needs k8s >= 1.29), so app containers start only after the DB is ready —
  this replaced the busybox wait-for-postgres init container. Server env
  `<PREFIX>_TYPEORM_HOST=localhost`. Deployment/Service/pod label = app name.
  Local verified 2026-10-04: 5 pods, seed data survived the re-shape because
  the PVC names were kept. `kubectl apply` does not prune, so the old per-tier
  Deployments/Services had to be deleted by hand once (staging/prod were
  never deployed, nothing to prune there).
- Base sets **no imagePullPolicy**. Local relies on the IfNotPresent default
  for `:local` tags; staging/prod overlays patch `Always` onto every container
  per Deployment (JSON patch paths are indexed, incl. `initContainers/0`).
- **Sizing (measured 2026-10-04 on minikube):** one env's containers use
  ~385 MB (servers 225, postgres 126, nginx 34); both envs < 800 MB; k3s +
  CoreDNS + Traefik ~500-600 MB. Target: **k3s on ONE t3.small (2 GB)**,
  staging + prod as namespaces. User explicitly does not want medium/large
  instances or techneip-scale infra. The two live t2.micro hosts (1 GB)
  cannot run k3s.
- **Ingress controller is Traefik, not ingress-nginx (changed 2026-10-04).**
  ingress-nginx is retired upstream and techneip-infra already moved to
  Traefik. `k8s/base/traefik` is raw manifests (v3.7.9, CRDs vendored from
  the upstream reference file, same as techneip). Routing is `IngressRoute` +
  `Middleware` CRDs, not core Ingress — techneip's cluster hit a Traefik bug
  where core Ingress never matched, so don't go back to it. Never add
  `--providers.kubernetescrd.ingressclass`: it silently drops Middlewares.
- **CORS:** the local overlay's `strip-origin` Middleware sets
  `customRequestHeaders: Origin: ""`, which deletes the header. Web and API
  share a host, so CORS isn't needed; the server takes its "no origin =>
  same origin" branch. Verified: POST with Origin -> 201 through Traefik.
  Staging/prod overlays do NOT strip — real hostnames are whitelisted in code.
- **API docs hosts redirect only the bare `/`** (`RedirectRegex` Middleware,
  302 to `/docs` or `/graphql`) on a `Host && Path(/)` route; everything else
  passes through. Swagger's relative asset and `docs-json` fetches then work
  with no extra rules. One IngressRoute holds all routes; Traefik gives longer
  rules higher priority automatically.
- **TLS (decided 2026-10-04): CloudFront + ACM in front, nothing in-cluster.**
  User chose CloudFront (~$1-2/mo, billed per request) over an ALB (~$18/mo
  flat) after hearing the trade-off: CloudFront -> instance is plain HTTP,
  restricted by security group to CloudFront's managed prefix list; the
  instance gets an Elastic IP. One ACM cert (us-east-1, required for
  CloudFront) covers all 14 staging+prod hosts; one distribution with 14
  aliases, caching disabled, origin request policy forwarding Host so Traefik
  can route by hostname. CloudFront does 80 -> 443. Traefik listens on `web`
  (plain HTTP) only in staging/prod — their IngressRoutes have no `tls:` block.
  **DNS: keep every existing hosted zone** (user's decision); terraform writes
  an alias record into each per-subdomain zone, deletes nothing. No cert-manager, no
  Let's Encrypt, no certbot, no Traefik ACME. Reason: the user is done with the
  90-day certbot cycle and rejected nginx; techneip's design (ACM at CloudFront
  + cert-manager for the CloudFront->NLB hop) is what failed — see §6. ACM certs
  can't be loaded into Traefik, so terminating at an AWS LB is the only way to
  have zero self-managed certs. The cloud Traefik controller will be a sibling
  of `base/traefik` without the websecure entrypoint/https redirect.
- Probes: tcpSocket on 3001 for servers, httpGet `/` for static tiers,
  `pg_isready -p <port>` for postgres.

### State at end of session (verified)

- minikube profile `incertotech` (docker driver, 6 GB / 4 CPU), Traefik v3.7.9
  in namespace `traefik` (minikube ingress addon disabled), Kubernetes v1.34.
- 5 pods Running (one per app; the three DB-backed ones show 2/2 or 1/1 plus
  a ready postgres sidecar), 0 restarts; 3 PVCs Bound.
- Verified 2026-10-04 through `kubectl -n traefik port-forward svc/traefik`:
  homepage 200 with `*.incertotech.local` links; both React apps 200; both
  REST APIs return seeded data; **POST with an `Origin` header returned 201**
  (CORS strip works); `/docs`, `/docs-json`, `/rest`, GraphQL playground and a
  GraphQL POST all 200; HTTP -> HTTPS 301. (GET /graphql needs
  `Accept: text/html` to get the playground; plain curl gets 400 — not a
  routing issue.)
- Not done (needs sudo, user must run): `/etc/hosts` entries and
  `make local-k8s-tunnel` (`sudo minikube tunnel -p incertotech`). Commands are printed at the end of
  `bin/start-local-k8s.sh` and in `k8s/README.md`. `make local-k8s-forward`
  is the no-sudo alternative (hosts entry still required).
- `k8s/certs/` contains the mkcert cert for `incertotech.local` +
  `*.incertotech.local`, gitignored.

### Terraform question (answered, nothing built)

User asked whether to use terraform like techneip. techneip's terraform has
three roots (shared: VPC, EKS w/ spot node groups, cluster-autoscaler IAM,
GitHub OIDC role, RDS + per-service Postgres DBs; staging/production: S3,
ACM, CloudFront, namespace) with local state files. For incertotech (DBs in
pods, no RDS) the recommendation was: one terraform root to start, containing
VPC, EKS + one spot node group, **EBS CSI driver addon + IRSA (required for
the in-pod Postgres PVCs)**, GitHub Actions OIDC role + access entry, and
Route53 records, **ALB + ACM certificate (replaces certbot; superseded the
original "cert-manager" idea on 2026-10-04, see §2 TLS)**; S3 backend for
state. Traefik and namespaces stay in Kubernetes. Flagged that EKS
costs several times the current single-EC2 setup; k3s on the existing EC2
would run the same overlays with near-zero terraform.

## 3. Safety rules for this machine

- `~/.kube/config` has EKS contexts for client projects, and the **global
  context defaults to `arn:aws:eks:us-east-2:...:cluster/techneip`**.
  A bare `minikube start` silently switches the global context, so start the
  cluster only via `make local-k8s-up` / `make local-k8s-start`, which pass
  `--keep-context`. **Always pass `--context=incertotech`.** Never
  `kubectl apply -k k8s/overlays/local` without it: the local overlay uses
  `imagePullPolicy: Never` and `:local` tags, so on a real cluster it creates
  10 unstartable pods. techneip's CLAUDE.md records a production outage from
  exactly that mistake.
- Do not edit the app repos (gitignored subdirs) for infra reasons; prefer
  ingress/overlay-level workarounds, as with the Origin strip.
- Do not touch `docker-compose*.yml`, `nginx/`, `run-*.sh`, or
  `.github/workflows/` for the k8s work unless the user asks.

## 4. Useful commands

```bash
make local-k8s-start          # full bootstrap (idempotent; rebuilds images)
make local-k8s-up             # start a stopped cluster only (never bare `minikube start`)
make local-k8s-start-quick    # apply only
make local-k8s-status
make local-k8s-logs svc=react-to-do-server
make local-k8s-restart svc=react-to-do-server
make local-k8s-render env=staging   # kustomize build for any overlay
make local-k8s-forward        # https://incertotech.local:8443 without sudo
make local-k8s-stop           # scale to 0, keep PVCs
make local-k8s-delete         # minikube delete -p incertotech

# quick curl check without /etc/hosts (port-forward on 9443 in another shell)
kubectl --context=incertotech -n traefik port-forward svc/traefik 9443:443
curl -sk --resolve react-to-do.incertotech.local:9443:127.0.0.1 https://react-to-do.incertotech.local:9443/api/categories
```

## 5. Open items / likely next steps

1. Run the two sudo commands and click through the apps in a browser.
2. **AWS account: RESOLVED 2026-10-04.** incertotech is account
   **249107242695**, CLI profile `incertotech-infra` (IAM user with
   AdministratorAccess, region us-east-1; the zsh switcher sets it under
   ~/dev/incertotech). Holds the two t2.micro hosts, every Route53 zone (one
   delegated zone per subdomain), nothing else relevant. 598988967350 was a
   2023 sandbox mislabeled "incertotech"; its root key was removed from the
   laptop (user still to delete it in that account + enable MFA).
3. **Cluster target: DECIDED — k3s on one new t3.small**, staging + prod as
   namespaces (not EKS, not the existing t2.micros). **Terraform is WRITTEN
   and validated (`terraform/{shared,staging,production,modules/edge}`), NOT
   applied.** Shared plan = 14 to add. State bucket
   `incertotech-terraform-state` exists (created by hand 2026-10-04, empty).
   Deploy workflow `.github/workflows/k8s-deploy.yml` (staging/prod dropdown, defaults to staging; prod only runs from main) + `k8s/base/traefik-cloud`
   are written. User paused 2026-10-04 to tweak the apps and test locally
   first; next action when they return: `terraform -chdir=terraform/shared
   apply`, then plan/apply staging + production (cutover=false), set the three
   repo variables the workflow needs, run the workflow for staging, test via
   the CloudFront domain with a Host header, then cutover staging, then prod.
   Design of what the terraform builds:
   EC2 t3.small + Elastic IP + security group (22 from user IP, 80 from
   CloudFront prefix list only), k3s install via user-data (disable the
   bundled traefik/servicelb; apply k8s/base/traefik cloud variant on :80
   only), ACM cert (14 SANs, DNS validation records in the respective
   sub-zones), CloudFront distribution (14 aliases, Host forwarded, no
   caching), alias records in each existing sub-zone, GitHub OIDC provider +
   role, SSM for the deploy workflow (no SSH keys / kubeconfig in GitHub).
   The two existing instances keep serving compose until DNS is cut over.
4. Staging/prod overlays currently pull floating `-latest` tags with
   `imagePullPolicy: Always`; a `kustomize edit set image` step with
   immutable tags (as techneip's deploy does) would make rollbacks real.
5. The compose setup's API routes go through public host ports; the k8s
   version already routes in-cluster. If/when the k8s deploy replaces compose,
   the server/postgres host port mappings and security-group rules can go.
6. Optional: add the local origin to each server's CORS whitelist in the app
   repos and drop the strip-origin Middleware, if editing app repos becomes
   acceptable.

## 6. 2026-10-04 session: certs, Traefik, techneip findings

- `portfolio/` now holds the four demo-app clones (homepage stays at root);
  `.gitignore`, `run-docker.dev.sh` and the bootstrap's `APPS` var reflect it.
- Live certs (checked 2026-10-03): prod and staging SAN certs issued Sep 30,
  valid to Dec 29 2026. The user renewed manually; the renew workflow kills
  every container, hence the motivation above.
- **Daily external cert check added:** `.github/workflows/tls-expiry-check.yml`
  opens TLS to all 14 public hostnames (prod + staging), verifies the chain, and
  fails if any cert is < 21 days from expiry or the handshake fails. GitHub's
  default failure notification is the alert. This is the check techneip lacked.
  It is the only file touched under `.github/workflows/`; deploy workflows are
  unchanged.
- **techneip-infra findings (read-only, nothing changed there):** cert-manager
  renewals have been failing for weeks. `staging-tls` expired 2026-09-09,
  `production-www-tls` expired 2026-08-19 — staging.techneip.com and
  www.techneip.com return 502 from CloudFront (origin_protocol_policy is
  https-only, so an expired origin cert = 502). `production-tls` expires
  **2026-10-18**; its renewal order has been pending since 09-18. Cause: HTTP-01
  challenges never get served — prod's ClusterIssuer solver still says
  `class: nginx-prod` (idle controller), staging's goes through Traefik's
  core-Ingress path that techneip documented as broken. Their own plan
  (`claude-plans/infrastructure/TRAEFIK_INGRESSROUTE_AND_DNS01_PLAN.md`, Part 2
  DNS-01) was never started. Public ACM certs at CloudFront are fine (prod to
  Dec 4 2026, staging to Mar 31 2027); the `*.techneip.com` ACM cert is FAILED
  (validation never completed). Simplest permanent fix for them: terminate TLS
  on the NLB with an ACM cert (`aws-load-balancer-ssl-cert` annotation) and
  delete cert-manager — same design incertotech now uses. Raised with the user;
  it's a separate project and their call.

## 7. 2026-10-07: node-ecommerce + django-blog added to k8s

- Both revived apps are now in `k8s/base/` as one pod each, same native-sidecar
  pattern as the others:
  - `node-ecommerce`: `mongo:8.0` sidecar (bound to localhost, `--wiredTigerCacheSizeGB 0.25`,
    bash `/dev/tcp` probes — mongosh probes were slow and ~150 MB each), a `seed` init
    container that `mongoimport`s the catalogue from the `node-ecommerce-seed` ConfigMap
    only when `products` is empty, and the Express app on :3000. Optional
    `node-ecommerce-stripe` secret for Stripe TEST keys.
  - `django-blog`: `postgres:17-alpine` sidecar (`PGDATA` subdir), gunicorn on :8000,
    entrypoint migrates + seeds. TCP probes (kubelet's Host header = pod IP, which
    ALLOWED_HOSTS rejects).
- Secrets: `k8s/ensure-secrets.sh <ns>` creates `node-ecommerce-secrets` (SESSION_SECRET)
  and `django-blog-secrets` (DJANGO_SECRET_KEY, POSTGRES_PASSWORD) with random values if
  missing; never in git. Run by `bin/start-local-k8s.sh` and by `k8s-deploy.yml` (uploaded
  to S3 next to the manifest, run on the node via SSM before `incertotech-deploy`).
- Hostnames: `node-ecommerce.` / `django-blog.` + `incertotech.local` | `staging.incertotech.com`
  | `incertotech.com`, in all three IngressRoutes and both terraform edge roots. The two
  new staging hosts have no hosted zone of their own; `modules/edge` gained
  `zone_for_host` to write them into `staging.incertotech.com`. Prod hosts reuse the existing
  legacy `node-ecommerce.incertotech.com` / `django-blog.incertotech.com` zones.
- Images: `incerto13/node-ecommerce` and `incerto13/django-blog`, built for linux/amd64
  (the Mac is arm64, the k3s node x86) with `docker buildx --platform linux/amd64 --push`.
  No CI builds them yet.
- Measured on minikube: node-ecommerce ~290 MB (web 168 + mongo 121), django-blog ~150 MB
  (web 118 + postgres 31) per environment. **Both envs with all apps is tight on a 2 GB
  t3.small** — measure on the real node after the first staging deploy before adding prod.
- `bin/start-local-k8s.sh` now `rollout restart`s deployments after a full rebuild (same
  `:local` tags hid new images; the homepage kept serving stale HTML).
- Homepage: local `build.env` points the two tiles at the `.incertotech.local` hosts. The
  homepage repo's staging/prod `ENVS` secrets must set `NODE_ECOMMERCE_URL` /
  `DJANGO_BLOG_URL` to the staging/prod hosts (user edits secrets).
