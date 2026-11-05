# 04 · Argo CD for people who hand out Helm charts (facilitator learning guide)

**Goal.** You normally give a customer a Helm chart and a values file. They run Argo CD, so what they actually do with it is write an Argo `Application`. This guide translates one into the other, using this repo and the Cast AI chart, so you can talk about it from the customer's side.

Not for Chris. It overlaps with [03-argo-handoff.md](03-argo-handoff.md), which is the answer key for his version of the task.

## 1. The mental model

Helm is a client-side tool: you run `helm install`, it renders templates and stores a release record in the cluster (a Secret). Argo CD is a controller that runs inside the cluster and does the rendering for you, then keeps comparing the result to what's live.

| You do this with Helm | The customer does this with Argo |
|---|---|
| `helm install castai castai-helm/castai --version X -f values.yaml` | Create an `Application` with `chart: castai`, `targetRevision: X`, and the values |
| Edit `values.yaml`, `helm upgrade` | Edit `values.yaml` in Git, push. Argo syncs |
| `helm rollback` | `git revert`, or Rollback in the Argo UI (history is per sync) |
| `helm list` | `kubectl -n argocd get applications` or the Argo UI |
| `helm uninstall` | Delete the Application (with the `resources-finalizer`, its resources are deleted too) |
| `helm diff upgrade` | The Diff view, and it's always on |
| `kubectl edit` on a Helm object (sticks) | Reverted by `selfHeal`, or flagged OutOfSync if self-heal is off |

**The difference that surprises people:** Argo does not run `helm install`. It runs `helm template` and applies the output. No Helm release Secret is created, so `helm list` shows nothing for Argo-managed charts. Anything that depends on Helm release state behaves differently:
- **Hooks** (`helm.sh/hook` annotations) are translated to Argo hooks. They mostly work, but they run on every sync and not just on install/upgrade.
- **`lookup`** doesn't work during `helm template`, because there is no live cluster to look at.
- **Random values** (`randAlphaNum` for a generated password) change on every render, so the app is permanently OutOfSync. Customers fix it by supplying the value, usually from an existing Secret.

Check whether the Cast chart does either of the last two. I haven't.

## 2. Three ways to deploy a chart from Git

1. **Inline values.** `helm.valuesObject` inside the Application. See [metrics-server.yaml](../gitops/apps/platform/metrics-server.yaml). It's the simplest, but values live inside Argo config.
2. **Chart from the Helm repo, values from Git (multi-source).** What [03-argo-handoff.md](03-argo-handoff.md) uses. The chart is pinned in one source and `values.yaml` in your repo is referenced with `$values/...`. This is what you'll see most at customers who want a reviewable values file.
3. **Wrapper chart.** A tiny chart in Git whose `Chart.yaml` lists the Cast chart as a dependency. Customers like it for pinning and for adding extra manifests. It adds a layer to explain.

For the Cast chart, option 2 is the natural one: the customer's mode changes (`readonly` → `node-autoscaler`) become a one-line PR to `values.yaml`.

## 3. Things to try, in order

1. **Open the UI.** `kubectl -n argocd port-forward svc/argocd-server 8080:80`, then log in as `admin`. The password command is in the `argocd_port_forward` output. Click through `nrg-root`, then `nrg-workloads`.
2. **Read the two status columns.** *Sync* means Git matches the cluster. *Health* means the thing is actually working. A crash-looping pod can be Synced and Degraded. Customers confuse these constantly.
3. **Watch self-heal.** `kubectl scale deploy/search --replicas=0 -n <ns>` on an Argo-managed Deployment and watch it return within seconds. Then do the same on `checkout-api` and notice it isn't reverted: that's the `ignoreDifferences` on its replicas in [workloads-app](../terraform/templates/workloads-app.yaml.tftpl).
4. **Make a change through Git.** Run `scripts/trap.sh 1 off --push` and watch Argo pick up the new commit. The default poll is about three minutes, so use *Refresh* or *Sync* in the UI to speed it up.
5. **Break something.** Point an Application at a chart version that doesn't exist, and see what a failed sync looks like in the UI. You'll need to read these errors on customer calls.
6. **Put the Cast chart under Argo.** After `castctl cluster connect` has run, follow the answer key in [03-argo-handoff.md](03-argo-handoff.md). Pay attention to whether Argo adopts the existing resources cleanly or reports them OutOfSync.

## 4. Things customers will ask (and what to say)

- **"Will Argo fight Cast AI?"** Cast mutates pods at admission and resizes in place, not the Deployment spec in Git. So Git and live state shouldn't diverge on what Cast changes. Where it can fight is anything Cast writes onto a controller-owned object. Verify on this cluster rather than promising it.
- **"Where does the API key go?"** Not in Git. A Secret created out of band, referenced by `global.castai.apiKeySecretRef`. Customers using Sealed Secrets or External Secrets can wire it in the same way.
- **"How do we change modes?"** Edit `tags:` in values, open a PR, merge. No `castctl` needed after the first install, apart from the cloud-side IAM that connect performs for node automation.
- **"Can we pin versions?"** Yes: `targetRevision` is the chart version. Don't leave it at `*` or `latest`.
- **"Does `castctl` still matter then?"** Yes for the first connect and for generating GitOps files (`castctl cluster migrate generate --format argocd`). Compare that output with the answer key.

## 5. Not verified

I wrote this from this repo's Argo files and the existing handoff guide. I have not run the Cast chart under Argo, so the claims about hooks, `lookup` and random values are general Helm/Argo behavior, not confirmed for the Cast chart. The "Will Argo fight Cast AI?" answer is the reasoning in 03, not an observed result. Item 6 is how you find out, and anything that fights should go back into this guide.
