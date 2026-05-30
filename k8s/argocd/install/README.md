# ArgoCD Installation

## 1. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

## 2. Wait for ArgoCD to be ready

```bash
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

## 3. Get initial admin password

```bash
argocd admin initial-password -n argocd
# OR
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## 4. Port-forward to ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open: https://localhost:8080  (admin / <password from step 3>)
```

## 5. Register your repository

```bash
argocd repo add https://github.com/asela-maduwantha/CloudMart \
  --username <github-user> \
  --password <github-pat>
```

## 6. Deploy ArgoCD Applications

```bash
# Staging (auto-sync on every push to develop)
kubectl apply -f k8s/argocd/applications/cloudmart-staging.yaml

# Production (manual sync required after approval)
kubectl apply -f k8s/argocd/applications/cloudmart-prod.yaml
```

## 7. Trigger sync from CI/CD

The CD pipeline calls `argocd app sync cloudmart-prod` after the manual approval gate.
This replaces `kubectl apply` with a GitOps-driven sync.

## Architecture

```
GitHub (main branch) ──push──> GitHub Actions (build + scan + push to ECR)
                                      │ manual approval
                                      ▼
                             argocd app sync cloudmart-prod
                                      │
                                      ▼
                             ArgoCD reads k8s/overlays/prod
                                      │
                                      ▼
                             EKS cluster cloudmart-prod namespace
```
