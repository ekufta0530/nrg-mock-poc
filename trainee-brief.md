# Northwind Retail Group (NRG): Customer Brief

You're the Sales Engineer on a new opportunity with **Northwind Retail Group**. You have a role-play meeting with **Dana Whitfield, VP of Platform Engineering**. Everything below is what the account team knows going in: facts only. Anything else, you need to discover.

Your mission: **discover** the current state and the real pain, **pitch the value** mapped to that pain, and **propose a scoped POC** that leaves the decision with the customer.

## Company

| | |
|---|---|
| What they do | Omnichannel retail: e-commerce site, store logistics, and a growing loyalty-data app |
| Size | ~4,000 employees, publicly traded |
| Revenue | ~$1.2B/yr |
| Engineering | ~450 engineers, ~25 in Platform/Infra |
| Cloud | **AWS** (primary), **GCP** (ML/recommendations), **Azure** (one acquired business unit) |
| Kubernetes | ~9 clusters across 3 clouds: EKS (prod, staging, dev), GKE (ML/recsys), AKS (acquired subsidiary) |
| Tooling | Terraform, Argo CD, GitHub Actions, Datadog + Prometheus |
| Approx. K8s spend | ~$310k/month across all clusters |
| Commercial | AWS EDP commitment in place; GCP and Azure on-demand |

## Kubernetes environment

- **EKS `nrg-prod-us-east-1`**: the crown jewel. ~180 microservices, ~1,400 pods steady state.
  - Node pools: `general` (m5, on-demand, self-managed node groups), `memory` (r5, on-demand), `burst` (c5, on-demand)
  - Node autoscaling: Kubernetes Cluster Autoscaler
  - Workloads: Java/Spring, Node.js, Go, some Python. Stateless APIs plus StatefulSets with persistent volumes (Elasticsearch, a few in-cluster Postgres instances)
- **EKS staging and dev**: smaller mirrors of prod. The staging cluster is **`nrg-stag-us-east-1`**.
- **GKE `nrg-ml-us-central1`**: recommendation/forecasting models; a handful of GPU node pools (NVIDIA T4/L4)
- **AKS `fenwick-fulfillment`**: came in with the Fenwick Fulfillment acquisition 8 months ago. Different stack, different team, on-demand VMs.

**On the platform team's roadmap (neutral facts):**
- A trial of Karpenter on the staging EKS cluster
- Migrating the acquired AKS workloads onto the main EKS platform (still in planning)
- Standardizing observability and SLOs across all clusters

## People

| Role | Who |
|---|---|
| VP Platform Engineering (economic buyer, your meeting) | Dana Whitfield |
| FinOps / cloud finance lead | TBD |
| SRE / reliability manager | TBD |
| App-team lead(s), acquired unit | TBD |
| Executive sign-off | CTO |

## What happens next

1. **Role-play** with Dana: discover, pitch, propose a POC (45-60 minutes), then a debrief
2. If Dana agrees to a POC, you'll **connect `nrg-stag-us-east-1`** (read-only first) and present what you find
3. Then run the POC against the success criteria you agreed
4. Readout

Treat it like a real customer. The staging cluster is their production-like environment, so ask before you change anything in it.
