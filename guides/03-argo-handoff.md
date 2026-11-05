# 03 · Cast AI under Argo CD (optional phase)

**Goal.** Dana already runs Argo CD, so "how does this fit our GitOps?" is a natural question. Chris should be able to show Cast AI managed from Git, and explain what changes.

## What good looks like
- He explains who owns what: Argo CD owns the platform, workloads and (optionally) the Cast AI chart; Cast AI owns node lifecycle and mutates pods at admission/in place, so Git manifests don't drift. This answers "will Argo fight WOOP?".
- He keeps secrets out of Git (API key by Secret reference).
- He knows the mode change becomes a Git change, and that going to node-autoscaler/full also needs the cloud-side setup (IAM) that `castctl cluster connect` performs.
- He knows the Cluster Autoscaler fix is a Git change too: `kubectl scale` is reverted by Argo's self-heal.

## Hint ladder
1. "What's the unit Argo deploys here?" (the umbrella chart `castai-helm/castai`, release in `castai-agent`)
2. "What did castctl set when it installed it?" (`helm -n castai-agent get values castai`)
3. "Where should the API key live?" (a Secret, referenced by `global.castai.apiKeySecretRef`)
4. "Is there a tool for generating the GitOps files?" (`castctl cluster migrate generate --format argocd`, for clusters on the older standalone charts)

## Answer key
```bash
# 1. what castctl installed
helm -n castai-agent list
helm -n castai-agent get values castai -o yaml > values.yaml
#    delete global.castai.apiKey; add   global.castai.apiKeySecretRef: castai-credentials   (key API_KEY, already created by the chart)
# 2. commit values.yaml, e.g. gitops/castai/values.yaml
# 3. Argo Application (multi-source: chart + values from Git)
```
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: castai, namespace: argocd }
spec:
  project: default
  sources:
    - repoURL: https://castai.github.io/helm-charts
      chart: castai
      targetRevision: <chart version from `helm list`>
      helm:
        releaseName: castai
        valueFiles: [$values/gitops/castai/values.yaml]
    - repoURL: <this repo>
      targetRevision: main
      ref: values
  destination: { server: https://kubernetes.default.svc, namespace: castai-agent }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```
```bash
# 4. apply it, wait Synced/Healthy, then drop Helm's release Secrets so Argo is the only owner (resources stay)
kubectl apply -f application.yaml
kubectl -n castai-agent delete secret -l owner=helm,name=castai
```
Changing mode afterwards: edit `tags:` in `values.yaml` (`readonly` → `workload-autoscaler` → `node-autoscaler`/`full`), push.

Gotchas worth a conversation: `prune: true` and the credentials Secret (it is not in Argo's rendered set, so it is not pruned, but a customer who templated it would lose it); chart hooks (the `kent` preflight) under Argo; pinning the chart version.

## Not verified
Built from `castai-helm/castai` 0.46.6 values (`apiKeySecretRef`, `tags.*`, `extraObjects`) and the `castctl cluster migrate generate` help. Adoption of live Helm-owned resources by Argo has not been tried; do it once yourself before a session and note anything that fights. Also try `castctl cluster migrate generate --format argocd --repo-url <repo> -o out/` and compare its output with the above.
