# Architecture

```mermaid
flowchart TB
    dev([Developer]) -->|PR| gh[(GitHub repo)]
    gh -->|"OIDC → WIF (keyless)"| ci["GitHub Actions<br/>lint · test · kubeconform · kind policy tests · plan"]

    subgraph supply["Secure supply chain"]
      cb["Cloud Build<br/>build → push → vuln scan"]
      kms[/"Cloud KMS<br/>asymmetric signing key"/]
      ar[("Artifact Registry<br/>immutable tags · scanning")]
      att["Binary Authorization<br/>attestor + policy"]
      cb --> ar
      cb -->|"sign digest"| kms
      kms --> att
    end

    subgraph delivery["Application delivery"]
      cd["Cloud Deploy pipeline<br/>staging → (approval) → prod canary 25/50/100"]
    end

    subgraph gcp["GCP project · europe-west1"]
      direction TB
      lb["Global external ALB<br/>Gateway API · static IP"]
      armor["Cloud Armor<br/>OWASP rules · rate limit"]
      subgraph vpc["VPC · private nodes · Cloud NAT"]
        subgraph gke["GKE Autopilot · Workload Identity · Dataplane V2"]
          argo["Argo CD<br/>platform layer (app-of-apps)"]
          subgraph ns["Namespaces (tenants)"]
            staging["shop-staging<br/>HPA"]
            prod["shop-prod<br/>canary"]
            ta["team-a"]
            tb["team-b"]
          end
          vap["ValidatingAdmissionPolicy<br/>CEL, in-API-server"]
          gmp["Managed Prometheus"]
        end
      end
      mon["Cloud Monitoring<br/>PromQL alerts · dashboard · uptime check"]
      bq[("BigQuery<br/>usage metering / cost by namespace")]
    end

    user([User]) --> armor --> lb --> prod
    lb --> staging
    ci -.->|release| cd
    cb -.->|signed digest| cd
    cd -->|deploy as executor SA| gke
    ar -->|image pull| gke
    att -->|"admission: signed only"| gke
    gh -->|sync| argo
    gmp --> mon
    gke -.-> bq
```

## Layers and owners

| Layer | Owner | Where |
|---|---|---|
| Cloud foundation (VPC, NAT, IAM, KMS, registry, WAF, budgets, alerts) | Terraform | `terraform/` |
| Cluster (Autopilot, private nodes, WI, Gateway API, Binary Authz, GMP) | Terraform | `terraform/modules/gke` |
| Cluster platform (namespaces, quota, netpol, policies, gateway, monitoring) | Argo CD | `gitops/` |
| Application releases | Cloud Deploy | `k8s/`, `skaffold.yaml` |
| Image build, scan, sign | Cloud Build | `cloudbuild.yaml` |
| Proof | scripts | `scripts/test.sh`, `tests/` |

## Request path
`Client → Cloud Armor (WAF/throttle) → Global ALB (Gateway API) → NEG → pod` (container-native, pod IPs as backends; no node hop).

## Release path
`git push → CI → Cloud Build (build · scan · sign) → Cloud Deploy release (digest-pinned) → staging (auto) → prod (approval → 25 % → 50 % → 100 %) → alert-driven rollback`.

## Admission path (three independent gates on every pod)
1. **Pod Security `restricted`** — how it runs.
2. **ValidatingAdmissionPolicy** — org rules (no `:latest`, team label, no public Services).
3. **Binary Authorization** — what it is (signed by our pipeline).
