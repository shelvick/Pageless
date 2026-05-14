# Pageless — simulated production stack

Kubernetes manifests for the workloads Pageless monitors. This is **not** how Pageless itself
deploys — it's the stand-in production environment whose `payments-api` deployment is the
demo's broken service. The agent watches THIS cluster, reads its logs/metrics, and (when an
operator approves) rolls back its deployments.

## What's here

```
k8s/
├── README.md                          # this file
└── manifests/
    ├── 00-namespaces.yaml             # prod + monitoring namespaces
    ├── 10-payments-api-v240.yaml      # good version (nginx, /health = 200)
    ├── 11-payments-api-v241.yaml      # bad version (nginx ConfigMap, /health = 500)
    ├── 20-blackbox-exporter.yaml      # blackbox-exporter + custom http_2xx_check module
    ├── 21-prometheus.yaml             # scrape config + PaymentsApiHealthDown rule + RBAC
    └── 22-alertmanager.yaml           # webhook receiver → ${PHX_VM_IP}/webhook/alertmanager
```

The two `payments-api` Deployments differ only in nginx config:
- `v2.4.0` returns `200 "ok"` on `/health`.
- `v2.4.1` returns `500 "ConnectionRefused: upstream payments-db"`.

Prometheus probes both via blackbox-exporter with a custom `http_2xx_check` module that
asserts status `[200]`. The `PaymentsApiHealthDown` rule fires on `probe_success == 0` for
30s, and Alertmanager POSTs an Alertmanager v4 webhook payload to the Phoenix host —
which is what Pageless ingests as an inbound alert.

## Provision a fresh cluster

Prerequisites: `vultr-cli` authenticated, local SSH pubkey, `kubectl`, `envsubst`.

```bash
# 1. Register your SSH pubkey (once per workstation)
vultr-cli ssh-key create --name "pageless-$(hostname)" --key "$(cat ~/.ssh/id_ed25519.pub)"
SSH_KEY_ID=<id-from-output>

# 2. Phoenix VM (bare — no app deployed by this packet)
vultr-cli instance create --region ewr --plan vc2-2c-4gb --os 2284 \
  --host pageless-phoenix --label pageless-phoenix --tags pageless \
  --ssh-keys "$SSH_KEY_ID"
# Poll until MAIN IP is non-zero, status=active.
PHX_VM_IP=<ip-from-output>

# 3. VKE cluster — note key:value (NOT key=value, despite CLI help prose)
vultr-cli kubernetes create --label pageless --region ewr --version "v1.35.2+1" \
  --node-pools "quantity:1,plan:vc2-2c-4gb,label:pageless-pool,tag:pageless"
# Poll until status=active. Then ~10s for API readiness, ~45s for first node Ready.
CLUSTER_ID=<id-from-output>

# 4. Managed Postgres
vultr-cli database create --database-engine pg --database-engine-version 16 \
  --region ewr --plan vultr-dbaas-hobbyist-cc-1-25-1 --label pageless-db
# Poll until status=Running.
PG_ID=<id-from-output>

# 5. IMMEDIATELY lock TRUSTED IPS (default is open, not closed)
vultr-cli database update "$PG_ID" --trusted-ips "$PHX_VM_IP"

# 6. Open port 80 on the VM — Ubuntu 24.04 image ships with ufw active
ssh root@"$PHX_VM_IP" 'ufw allow 80/tcp'

# 7. Fetch kubeconfig (base64-wrapped on Vultr's side)
mkdir -p ~/.kube
vultr-cli kubernetes config "$CLUSTER_ID" | base64 -d > ~/.kube/pageless.yaml
chmod 600 ~/.kube/pageless.yaml
export KUBECONFIG=~/.kube/pageless.yaml
kubectl get nodes  # wait for Ready

# 8. Apply manifests
kubectl apply -f manifests/00-namespaces.yaml
kubectl apply -f manifests/10-payments-api-v240.yaml
kubectl apply -f manifests/11-payments-api-v241.yaml
kubectl apply -f manifests/20-blackbox-exporter.yaml
kubectl apply -f manifests/21-prometheus.yaml
PHX_VM_IP="$PHX_VM_IP" envsubst < manifests/22-alertmanager.yaml | kubectl apply -f -
```

## Verify

```bash
# Pods Running
kubectl -n prod get pods
kubectl -n monitoring get pods

# Probes hitting the right targets
kubectl -n monitoring port-forward svc/prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=probe_success{job="payments-api-blackbox"}' \
  | python3 -m json.tool
# Expected: v2-4-0 instance → "1", v2-4-1 instance → "0"

# Rule firing
curl -s 'http://localhost:9090/api/v1/alerts' | python3 -m json.tool
# Expected: PaymentsApiHealthDown, state=firing

# End-to-end webhook (stand-in listener until Pageless app is deployed)
ssh root@"$PHX_VM_IP" 'python3 -m http.server 80 --bind 0.0.0.0' &
# Wait up to 60s. Webhook POST arrives with Alertmanager v4 JSON.
```

## Teardown

```bash
vultr-cli kubernetes delete <CLUSTER_ID> --delete-resources
vultr-cli database delete   <PG_ID>
vultr-cli instance delete   <VM_ID>
vultr-cli ssh-key delete    <SSH_KEY_ID>
```

Expected run-rate while up: ~$2/day (VKE node + DB + VM combined).

## Gotchas

1. **Ubuntu 24.04 image ships with `ufw` active**, allowing only port 22. Inbound 80 is
   silently dropped until you `ufw allow 80/tcp` on the VM. Surfaces as Alertmanager
   `context deadline exceeded` with no other signal.
2. **`vultr-cli kubernetes create --node-pools` uses `key:value` separators**, not
   `key=value` — mismatching the CLI help's prose.
3. **VKE control plane "active" status precedes API readiness by ~10s**, and worker node
   `NotReady → Ready` takes another ~45s. Plan ~3.5min total cluster-create-to-first-pod.
4. **Vultr Managed PG TRUSTED IPS default is OPEN** (empty allowlist = no restriction).
   Lock immediately after the database reaches `Running` state — don't leave a window.
5. **Vultr kubeconfig is base64-wrapped** — must `base64 -d` before kubectl can read it.
