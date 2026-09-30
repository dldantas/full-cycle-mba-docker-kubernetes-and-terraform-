#!/usr/bin/env sh
# Gera carga na API de DENTRO do cluster (hey) e acompanha o HPA escalando.
#   ./infra/scripts/load-test.sh [duração] [concorrência]
set -eu

DURATION="${1:-120s}"
CONCURRENCY="${2:-50}"
NS="${NS:-mural}"
KUBECONFIG="${KUBECONFIG:-$(cd "$(dirname "$0")/../terraform" && pwd)/.kube/mural-config}"
export KUBECONFIG

echo ">> HPA antes da carga"
kubectl -n "$NS" get hpa mural-api

echo ">> disparando hey por $DURATION com $CONCURRENCY conexões"
kubectl -n "$NS" delete pod loadgen --ignore-not-found >/dev/null
kubectl -n "$NS" run loadgen --image=williamyeh/hey:latest --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"loadgen","image":"williamyeh/hey:latest","args":["-z","'"$DURATION"'","-c","'"$CONCURRENCY"'","http://mural-api/api/messages"],"resources":{"requests":{"cpu":"100m","memory":"32Mi"},"limits":{"cpu":"1","memory":"128Mi"}}}]}}'

# Observa o HPA enquanto a carga roda.
kubectl -n "$NS" get hpa mural-api --watch &
WATCH=$!
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/loadgen --timeout=600s >/dev/null || true
kill "$WATCH" 2>/dev/null || true

echo ">> resumo do hey"
kubectl -n "$NS" logs loadgen | sed -n '/Summary/,/Latency distribution/p'
kubectl -n "$NS" delete pod loadgen --ignore-not-found >/dev/null

echo ">> HPA e pods depois da carga (o scale-down vem após a janela de estabilização)"
kubectl -n "$NS" get hpa mural-api
kubectl -n "$NS" get pods -l app.kubernetes.io/component=api
