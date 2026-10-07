# incertotech-infra — Claude instructions

Read `K8S_CONTEXT.md` first. It holds the full context of the Kubernetes
experiment, the compose setup it mirrors, and the safety rules.

## Non-negotiables

- The live deployment is docker-compose on EC2 (`docker-compose.yml`, `nginx/`,
  `.github/workflows/`). The `k8s/` directory is a side-by-side experiment.
  Do not change the compose deployment for k8s work unless asked.
- Always `kubectl --context=incertotech` (the Makefile and
  `bin/start-local-k8s.sh` already do). The global kubectl context on this
  machine is a client's production EKS cluster. Never apply `k8s/overlays/*`
  to it.
- `homepage/` and the four demo apps under `portfolio/` (`react-to-do/`,
  `react-electoral-map/`, `react-course-admin/`, `nest-blog-api/`) are separate
  git repos (gitignored here). Treat edits to them as changes to another project.

## Local k8s

```bash
make local-k8s-start      # minikube profile "incertotech", builds images, deploys
make local-k8s-up         # start a stopped cluster only
make local-k8s-status
```
Never run a bare `minikube start`: it switches the global kubectl context to
`incertotech`. The make targets pass `--keep-context`.
Browser access needs `/etc/hosts` entries + `make local-k8s-tunnel` (runs `sudo minikube tunnel -p incertotech`)
(see `k8s/README.md`).
