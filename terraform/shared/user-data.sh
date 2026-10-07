#!/bin/bash
# First-boot bootstrap for the incertotech k3s node (Amazon Linux 2023).
# Runs once. Changing this file does NOT touch a running instance
# (lifecycle.ignore_changes in main.tf).
set -euxo pipefail

# k3s, single node. The bundled Traefik is disabled: the cluster runs its own
# from k8s/base/traefik-cloud (deployed by the first workflow run). servicelb
# (klipper) stays enabled so that Traefik's LoadBalancer Service binds host :80,
# which is what CloudFront talks to.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --write-kubeconfig-mode 644" sh -

# kustomize, same pinned version techneip's workflows use
KUSTOMIZE_VERSION=5.5.0
curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
  | tar -xz -C /usr/local/bin

# Deploy helper invoked by GitHub Actions through SSM Run Command:
#   incertotech-deploy s3://<bucket>/<env>/<sha>.yaml
# The workflow renders `kustomize build k8s/overlays/<env>` in Actions and
# uploads the result; nothing on this box needs git or GitHub access.
cat > /usr/local/bin/incertotech-deploy <<'EOF'
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
uri="$1"
f="$(mktemp /tmp/deploy.XXXXXX.yaml)"
aws s3 cp "$uri" "$f"
kubectl apply --server-side --force-conflicts -f "$f"
# wait for whatever namespaces the manifest touched
for ns in $(grep -E '^  namespace: ' "$f" | awk '{print $2}' | sort -u); do
  kubectl -n "$ns" wait --for=condition=available deployment --all --timeout=300s
done
rm -f "$f"
EOF
chmod +x /usr/local/bin/incertotech-deploy

# Convenience for `aws ssm start-session` shells.
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' > /etc/profile.d/k3s.sh
