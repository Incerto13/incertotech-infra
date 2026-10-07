docker-stop:
	@containers=$$(docker ps -q); \
	if [ -n "$$containers" ]; then \
		echo "Stoppig all running containers..."; \
		docker stop $$containers; \
	else \
		echo "No running containers to stop."; \
	fi
	docker system prune -af

docker-prune-all:
	docker system prune -af
	docker image prune -af
	docker volume prune -af

# =============================================================================
# Local Kubernetes (minikube + kustomize) — side-by-side with docker-compose
# =============================================================================
# Everything targets the "incertotech" minikube profile via --context so the
# global kubeconfig context is never used (and never changed).

PROFILE   ?= incertotech
NAMESPACE ?= incertotech-local
KC  := kubectl --context=$(PROFILE) -n $(NAMESPACE)
KCB := kubectl --context=$(PROFILE)

.PHONY: _ensure-local-ctx
_ensure-local-ctx:
	@kubectl config get-contexts $(PROFILE) >/dev/null 2>&1 || \
		(echo "❌ minikube context '$(PROFILE)' not found. Run: make local-k8s-start" && exit 1)

# The only place minikube is started. --keep-context stops minikube from
# switching the global kubectl context (a client's prod EKS on this machine).
local-k8s-up:               ## start (or create) the cluster only; no build/deploy
	@if minikube status -p $(PROFILE) 2>/dev/null | grep -q "host: Running"; then \
		echo "✅ minikube '$(PROFILE)' already running"; \
	else \
		minikube start -p $(PROFILE) --memory=6144 --cpus=4 --driver=docker --keep-context; \
	fi

local-k8s-start: local-k8s-up              ## create cluster, build images, deploy
	bin/start-local-k8s.sh

local-k8s-start-quick: local-k8s-up        ## redeploy without rebuilding images
	bin/start-local-k8s.sh --skip-build

local-k8s-apply: _ensure-local-ctx         ## kubectl apply -k overlays/local
	$(KCB) apply --server-side --force-conflicts -k k8s/overlays/local

local-k8s-diff: _ensure-local-ctx          ## show what apply would change
	$(KCB) diff -k k8s/overlays/local || true

local-k8s-render:           ## print rendered manifests for an overlay (env=local|staging|prod)
	kustomize build k8s/overlays/$(or $(env),local)

local-k8s-status: _ensure-local-ctx
	$(KC) get pods,svc,ingressroute,middleware,pvc

local-k8s-logs: _ensure-local-ctx          ## make local-k8s-logs svc=react-to-do-server
	@[ -n "$(svc)" ] || (echo "usage: make local-k8s-logs svc=<deployment>" && exit 1)
	$(KC) logs deploy/$(svc) -f --tail=100

local-k8s-restart: _ensure-local-ctx       ## make local-k8s-restart svc=react-to-do-server
	@[ -n "$(svc)" ] || (echo "usage: make local-k8s-restart svc=<deployment>" && exit 1)
	$(KC) rollout restart deploy/$(svc)

# Rebuild + roll just the homepage after editing homepage/ (no cluster restart).
# index.html is GENERATED from index-no-links.html + build.env here, so edit
# index-no-links.html (and css/, img/, vendor/), never index.html directly.
local-k8s-homepage: _ensure-local-ctx      ## rebuild the homepage image and roll its pod
	@set -a; . k8s/overlays/local/build.env; set +a; \
	for v in REACT_COURSE_ADMIN_URL REACT_ELECTORAL_MAP_URL REACT_TO_DO_URL NEST_TO_DO_API_URL NEST_BLOG_API_URL NEST_COURSE_ADMIN_API_URL NODE_ECOMMERCE_URL DJANGO_BLOG_URL; do \
		eval "echo $$v=\$$$$v"; \
	done > homepage/.env
	@cd homepage && bash expand-homepage-links.sh index-no-links.html index.html >/dev/null
	@eval "$$(minikube -p $(PROFILE) docker-env)" && \
		tar -C homepage --exclude=node_modules --exclude=.git --exclude='*.md' --exclude=.env --exclude=.dockerignore -cf - . | docker build -q -t homepage:local - >/dev/null
	$(KC) rollout restart deploy/homepage
	@$(KC) rollout status deploy/homepage --timeout=120s
	@echo "✅ homepage updated — hard-refresh https://incertotech.local (Cmd+Shift+R)"

local-k8s-tunnel: local-k8s-up             ## expose Traefik on :80/:443 (sudo; keep running in its own terminal)
	@echo "https://incertotech.local — Ctrl+C to stop"
	sudo minikube tunnel -p $(PROFILE)

local-k8s-forward: _ensure-local-ctx       ## no-sudo access: forward Traefik to localhost:8443
	@echo "https://incertotech.local:8443  (and every *.incertotech.local:8443) — Ctrl+C to stop"
	$(KCB) -n traefik port-forward svc/traefik 8443:443

local-k8s-stop: _ensure-local-ctx          ## scale everything to 0, keep PVC data
	$(KC) scale deployment --all --replicas=0

local-k8s-delete:           ## destroy the minikube profile entirely
	minikube delete -p $(PROFILE)
