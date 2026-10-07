# incertotech on Kubernetes (experimental, side-by-side)

This directory is a Kubernetes rendering of what `docker-compose.yml` +
`nginx/default.conf-<env>` do today. **Nothing here is used by the existing
EC2 / docker-compose / GitHub Actions deployment** — it's an experiment that
runs next to it. The layout copies the pattern used in `techneip-infra/k8s`:

```
k8s/
  base/                 one folder per app: Deployment + Service (+ PVC for postgres)
  overlays/
    local/              minikube — images built locally, *.incertotech.local ingress
    staging/            scaffold — incerto13/*:staging-latest, *.staging.incertotech.com
    prod/               scaffold — incerto13/*:prod-latest, *.incertotech.com
  certs/                mkcert output for local TLS (gitignored)
  base/traefik/         Traefik controller (+ ../traefik-crds); applied standalone
bin/start-local-k8s.sh  one-shot: cluster -> traefik -> images -> deploy
```

## How it maps onto the compose setup

| docker-compose / nginx-proxy                        | kubernetes                                               |
|-----------------------------------------------------|----------------------------------------------------------|
| one compose project per app (postgres + server + web) | **one pod per app**: those containers share a pod; one Service exposes :80 and :3001 |
| image `incerto13/<name>:${ENV}-latest`              | base uses bare `<name>`; overlay `images:` sets registry+tag |
| `ports: 8110:3001` + nginx `proxy_pass host:8110`    | ClusterIP Service on 3001, Ingress routes to it directly |
| nginx `server { server_name x; location / {...} }`  | one `Host(...)` rule in the Traefik IngressRoute          |
| nginx `location /api { proxy_pass ...server }`      | `Host(...) && PathPrefix(/api)` rule to the server Service |
| nginx-proxy + certbot volume                        | local: Traefik + mkcert Secret; cloud: AWS ALB + ACM cert |
| `.env` block per ENV                                | overlay per ENV                                          |
| postgres data inside the container                  | PersistentVolumeClaim (survives pod restarts)            |

Each app is exactly one pod (a portfolio-wide rule, see `K8S_CONTEXT.md` §2):
postgres runs as a *native sidecar* initContainer (`restartPolicy: Always` +
a `pg_isready` startupProbe, so the server only starts once the DB is up), the
server reaches it on `localhost`, and the web container sits beside them. The
Deployment, Service and pod label are all named after the app
(`react-to-do`); image names keep the underscore (`react-to-do_web`) so the
staging/prod overlays line up with the existing Docker Hub repos.

The API docs subdomains (`nest-to-do-api`, `nest-course-admin-api`,
`nest-blog-api`) use a `RedirectRegex` Middleware on the bare `/` only (to
`/docs` or `/graphql`) instead of the nginx `proxy_pass .../docs/` rewrite, so
Swagger's relative asset and `docs-json` fetches work without extra rules.

## Ingress and TLS: Traefik, no cert-manager

The ingress controller is **Traefik v3.7.9** (`base/traefik`, raw manifests,
same version and CRDs techneip-infra vendors). Routing uses Traefik's
`IngressRoute` + `Middleware` CRDs, not core `Ingress`. ingress-nginx is gone:
it is retired upstream and techneip already migrated off it.

TLS design for the cloud (decided 2026-10-04, see `K8S_CONTEXT.md`): one **AWS
ALB in front of the cluster with an ACM certificate** covering all seven hosts.
ACM renews it automatically; the ALB does the 80 -> 443 redirect; Traefik only
listens on plain HTTP (`web` entrypoint) and routes. **No cert-manager, no
Let's Encrypt, no certbot** — nothing inside the cluster has an expiry. This is
deliberately simpler than techneip, whose in-cluster Let's Encrypt cert (needed
for the CloudFront -> NLB hop) expired unnoticed and took staging down.

Locally Traefik terminates TLS itself with the mkcert Secret and redirects
http -> https, so the browser experience matches the real site.

## Local (minikube)

```bash
make local-k8s-start          # first time: creates profile "incertotech", builds, deploys
make local-k8s-up             # just start a stopped cluster (after a reboot / Docker restart)
make local-k8s-start-quick    # redeploy without rebuilding images
make local-k8s-status
make local-k8s-logs svc=react-to-do-server
```

Then one-time host setup (needs sudo):

```bash
sudo sh -c 'echo "127.0.0.1 incertotech.local react-to-do.incertotech.local react-electoral-map.incertotech.local react-course-admin.incertotech.local nest-to-do-api.incertotech.local nest-blog-api.incertotech.local nest-course-admin-api.incertotech.local" >> /etc/hosts'
make local-k8s-tunnel                  # sudo minikube tunnel; keep running in its own terminal
```

and open https://incertotech.local. Without sudo, `make local-k8s-forward`
port-forwards Traefik to `localhost:8443` and the same hosts
work on that port (still needs the /etc/hosts line).

What the bootstrap script does, in order:

1. `make local-k8s-up` runs `minikube start -p incertotech --keep-context`
   (docker driver, 6 GB / 4 CPU) before the script. `--keep-context` leaves
   your global kubectl context alone; every command uses
   `--context=incertotech` explicitly. Don't run a bare `minikube start`.
2. Applies `base/traefik` (CRDs + controller, namespace `traefik`) and disables
   the legacy minikube `ingress` addon if a previous run enabled it.
3. mkcert certificate for `incertotech.local` + `*.incertotech.local` ->
   Secret `incertotech-tls`.
4. Generates the same build-time files the per-app `run-docker.dev.sh` scripts
   do (`web/.env`, `homepage/.env`, `homepage/index.html`) from
   `overlays/local/build.env`, then builds all 10 images **inside minikube's
   docker daemon** tagged `:local`. Build contexts are streamed as tar with
   `node_modules` excluded.
5. `kubectl apply --server-side -k k8s/overlays/local`, deletes any leftover
   core `Ingress` objects from the ingress-nginx era, and waits for rollout.

### Why the local overlay strips the `Origin` header

Each Nest server has a hard-coded CORS whitelist of the real
`*.incertotech.com` hostnames. Browsers send `Origin` on every non-GET request,
even same-origin ones, so a POST from `https://react-to-do.incertotech.local`
would get `Not allowed by CORS`. Web and API share a host behind the ingress,
so CORS isn't needed; the local overlay's `strip-origin` Middleware
(`headers.customRequestHeaders: Origin: ""` — an empty value deletes the header)
drops it and the server takes its "no origin => same origin" path. This is
local-only. Staging/prod hostnames are already whitelisted in the app code.

## Staging / prod overlays

These render (`make local-k8s-render env=staging`) but are not deployed
anywhere. To use them you'd need a cluster running `base/traefik` (a cloud
variant without the https redirect), an ALB with an ACM certificate in front of
Traefik's Service, Route53 alias records for the seven hosts, and a workflow
that runs `kubectl apply -k k8s/overlays/<env>`.
The images are the same `incerto13/*:<env>-latest` tags the compose setup
pulls, so no app rebuilds are needed to try it.

## Safety

The kubeconfig on this machine also has EKS contexts for other projects.
Never run `kubectl apply -k k8s/overlays/local` without `--context=incertotech`
(the Makefile and script always pass it). The local overlay uses
`imagePullPolicy: Never` and `:local` tags that only exist in minikube, so
applying it to a real cluster would produce 10 unstartable pods.
