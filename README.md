# Mural de Recados: do compose ao cluster

Solução do desafio **Docker + Kubernetes + Terraform** (Full Cycle). A aplicação (`app/api`, `app/web`) não foi alterada. Toda a entrega é infraestrutura:

| Onde | O quê |
|------|-------|
| [`docker-compose.yml`](docker-compose.yml) | Ambiente de dev com imagens oficiais (db → migrate → api → web). Serve para entender a app. |
| [`app/docker/`](app/docker) | `api.Dockerfile` (multi-stage → distroless) e `web.Dockerfile` (nginx + proxy `/api` por env). |
| [`infra/helm/mural/`](infra/helm/mural) | Helm chart: Deployments, StatefulSet + PVC, Services, Ingress, ConfigMaps, Secret, Job de migração (hook), HPA. |
| [`infra/terraform/`](infra/terraform) | Maestro: cluster kind → build/load das imagens → Traefik (+ metrics-server) → namespace → chart. |
| [`infra/scripts/load-test.sh`](infra/scripts/load-test.sh) | Bônus: carga com `hey` e acompanhamento do HPA. |
| [`Makefile`](Makefile) | Bônus: `make up`, `make down`, `make cycle`, etc. |

Arquitetura-alvo: [docs/arquitetura.md](docs/arquitetura.md).

## Como rodar

**Pré-requisitos:** Docker, [kind](https://kind.sigs.k8s.io/) **≥ v0.29** (usado pelo `kind load docker-image`), Terraform ≥ 1.6 e `kubectl` (opcional, para inspecionar). O Helm CLI não é necessário, porque o provider do Terraform já embute o Helm. As portas 80 e 443 do host precisam estar livres.

```bash
make up        # terraform init + apply + smoke test
# abra http://mural.localtest.me

make idempotency   # terraform plan -detailed-exitcode → "nenhuma mudança pendente"
make status        # pods, svc, ingress, pvc, job, hpa
make load-test     # bônus: HPA sob carga
make down          # terraform destroy

make cycle         # prova completa: apply → plan (0 changes) → destroy
```

Sem `make`:

```bash
cd infra/terraform
terraform init
terraform apply          # do zero até o Mural respondendo
terraform apply          # "No changes." / 0 added, 0 changed, 0 destroyed
terraform destroy        # remove cluster, imagens e tudo que foi criado
```

Para inspecionar o cluster: `export KUBECONFIG=$PWD/infra/terraform/.kube/mural-config` (o Terraform escreve um kubeconfig próprio e não mexe no seu `~/.kube/config`).

Se as portas 80/443 estiverem ocupadas, use `terraform apply -var http_port=8080 -var https_port=8443` e acesse `http://mural.localtest.me:8080`.

**Ambiente de dev (compose):** `make compose-up` (gera um `.env` com senha aleatória se ele não existir), ou `cp .env.example .env`, preencha `POSTGRES_PASSWORD` e rode `docker compose up`. Depois abra http://localhost:8080. O compose não traz senha default: sem `.env`, ele recusa subir.

## Docker: tamanho da imagem da API

| Imagem | Tamanho |
|--------|---------|
| `golang:1.23` (base "cheia", o ponto de partida do enunciado) | 1.23 GB |
| `golang:1.23-alpine` (a que o compose usa com `go run`) | 370 MB |
| Single-stage ingênuo (`golang:1.23-alpine` + código + `go build`) | 620 MB |
| **`mural-api` final (multi-stage → `distroless/static:nonroot`)** | **18.9 MB** |

Isso dá uma imagem **~33x menor** que o single-stage e ~65x menor que a `golang` padrão. O que produz esse resultado:

- **`CGO_ENABLED=0`**: o binário é 100% estático e não depende de libc, então roda numa imagem sem sistema operacional.
- **`-trimpath -ldflags="-s -w"`**: remove caminhos locais, tabela de símbolos e informação de debug.
- **`gcr.io/distroless/static-debian12:nonroot`** em vez de `scratch`: custa ~2 MB e traz CA certs, tzdata e o usuário `nonroot` (uid 65532) prontos. Não tem shell nem gerenciador de pacotes, então a superfície de ataque é mínima.
- **Cache de dependências**: `go.mod`/`go.sum` são copiados antes do código, então `go mod download` só roda de novo quando as dependências mudam.

O front usa `nginxinc/nginx-unprivileged:1.27-alpine` (a variante oficial não-root do nginx, que escuta em 8080). O template `nginx.conf.template` vai para `/etc/nginx/templates/`, e o entrypoint do nginx roda `envsubst` no boot. Assim `API_UPSTREAM` vem do ambiente e a **mesma imagem** serve no compose (`api:8080`) e no cluster (`mural-api:80`) sem rebuild.

## Decisões

### As três fricções

1. **Migração antes da API: Job como hook `post-install,post-upgrade`.** O hook não pode ser `pre-install` porque nessa fase o Postgres e o Secret ainda não existem. No `post-*` eles já foram aplicados. O Job espera o banco com `pg_isready`, aplica `files/migrations/*.sql` em ordem (montados de um ConfigMap) com `ON_ERROR_STOP` e termina. Com `before-hook-creation`, o Job é recriado a cada release. Re-rodar é seguro porque as migrations são idempotentes (`CREATE TABLE IF NOT EXISTS` e seed condicional).
2. **Liveness ≠ readiness.** A `livenessProbe` usa `/healthz`, que só verifica se o processo está vivo e não toca no banco. A `readinessProbe` usa `/readyz`, que exige banco e tabela. Durante a migração os pods da API ficam `Running` mas fora do Service, e depois viram Ready **sem nenhum restart** (verificado: `RESTARTS 0`). Com a liveness em `/readyz`, o kubelet mataria os pods em loop antes de a migração terminar.
3. **Segredo é Secret.** A senha é gerada pelo Terraform (`random_password`) e passada ao chart com `set_sensitive`. O chart monta um Secret com `POSTGRES_*` e `DATABASE_URL` (senha codificada para URL). A API e o Job recebem a URL via `secretKeyRef`, e o Postgres recebe as variáveis via `envFrom.secretRef`. O `values.yaml` versionado tem `password: ""`, e o chart **falha de propósito** (`required`) se nenhuma senha nem `existingSecret` for informado. Nenhum arquivo versionado contém credencial.

### Helm

- **Postgres em StatefulSet + `volumeClaimTemplates`** (PVC `data-mural-postgres-0`, StorageClass `standard` do kind), com um Service headless para identidade estável. `PGDATA` fica num subdiretório do volume porque o `initdb` exige diretório vazio. Testado: apagar o pod do Postgres não perde recados.
- **requests/limits** em todos os workloads, inclusive no Job de migração.
- **ConfigMap** com `PORT` e `API_UPSTREAM`. Os pods têm anotações `checksum/config` e `checksum/secret`, então trocar config ou senha dispara rollout automático.
- **Segurança**: API com `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: [ALL]` e sem privilege escalation. Front e Job também rodam como não-root.
- **Ingress (Traefik)**: `/api` vai para o Service da API e `/` para o front, no host `mural.localtest.me` (resolve para 127.0.0.1, dispensa `/etc/hosts`).
- **Tudo parametrizável** em `values.yaml`: imagens/tags, réplicas, recursos, probes, host, classe do ingress, storage, credencial / `existingSecret` e HPA.

### Terraform

- **Providers**: `tehcyx/kind` (cluster), `hashicorp/helm` (Traefik, metrics-server, Mural), `hashicorp/kubernetes` (namespace `mural`) e `hashicorp/random` (senha). Os providers helm e kubernetes são configurados com as saídas do `kind_cluster` (endpoint e certificados), então não dependem de contexto do `~/.kube/config`.
- **Cluster kind** com o label `ingress-ready=true` e `extraPortMappings` host 80/443 → nó 30080/30443. O Traefik é instalado com Service `NodePort` fixo nessas portas, o que leva o tráfego de `localhost:80` ao Ingress.
- **Imagens**: um `terraform_data` por imagem roda `docker build` e `kind load docker-image`. **A tag é o hash do conteúdo** (Dockerfile + contexto). Código igual gera a mesma tag, e nada roda de novo. Código alterado gera outra tag, com rebuild, load e rollout, sem depender de `latest`. O cluster também entra nos triggers, então um cluster recriado recebe as imagens outra vez. No destroy (ou na troca de tag), a imagem antiga é removida do Docker local. O comando usa caminhos relativos e nenhuma aspa, para funcionar tanto em `sh` quanto em `cmd.exe`.
- **`wait = false` na release do Mural, de propósito.** Com `--wait`, o Helm espera os Deployments ficarem Ready **antes** de rodar hooks `post-install`. Mas a API só fica Ready **depois** do hook de migração, então haveria deadlock. Sem `--wait`, o Helm aplica os recursos e bloqueia no hook até o Job terminar com sucesso, porque hooks são sempre aguardados. Resultado: o `apply` só retorna com o schema criado, e a API fica Ready alguns segundos depois.
- **Idempotência**: versões de charts e da imagem do nó são fixadas, a senha fica no state, as tags vêm do conteúdo e não há `timestamp()` nem `latest`. Com HPA ligado, o chart omite `replicas` do Deployment, então o HPA escalar os pods não gera drift. Verificado: depois de escalar para 6 réplicas, `terraform plan` continua com **No changes**.
- **Destroy**: remove as releases, o namespace (com PVC e Job) e o cluster kind. As imagens `mural-*` construídas pelo Terraform também são apagadas do Docker local.

## Evidências (Windows 11 + Docker Desktop, kind v0.29, Terraform 1.9)

```text
# 1º apply (ambiente limpo): ~2 min
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
url = "http://mural.localtest.me"

# 2º apply
No changes. Your infrastructure matches the configuration.
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.

$ kubectl -n mural get pods,job,pvc
pod/mural-api-94fcf86cb-hfqfp   1/1  Running    0
pod/mural-api-94fcf86cb-w7dpb   1/1  Running    0
pod/mural-migrate-mp2kr         0/1  Completed  0
pod/mural-postgres-0            1/1  Running    0
pod/mural-web-8cdcbfc6-ll2qv    1/1  Running    0
pod/mural-web-8cdcbfc6-qw4sx    1/1  Running    0
job.batch/mural-migrate   Complete   1/1
persistentvolumeclaim/data-mural-postgres-0   Bound   1Gi   RWO   standard

$ kubectl -n mural logs job/mural-migrate
aguardando o Postgres...
aplicando /migrations/001_init.sql
aplicando /migrations/002_seed.sql
migrations aplicadas

# destroy
Destroy complete! Resources: 8 destroyed.
$ kind get clusters
No kind clusters found.
```

### Bônus: HPA sob carga

HPA na API: CPU alvo de 50% do request, de 2 a 6 réplicas. O metrics-server é instalado pelo Terraform com `--kubelet-insecure-tls`, necessário no kind. O `make load-test` roda o `hey` **dentro** do cluster contra o Service da API (120 s, 50 conexões):

```text
NAME        REFERENCE              TARGETS         MINPODS   MAXPODS   REPLICAS
mural-api   Deployment/mural-api   cpu: 329%/50%   2         6         6

Summary:
  Total:        120.07 secs
  Requests/sec: 2264.47
  Average:      0.0221 secs

mural-api-94fcf86cb-h9hr2   1/1   Running   0   102s   <- criado pelo HPA
mural-api-94fcf86cb-hfqfp   1/1   Running   0   3m57s
mural-api-94fcf86cb-lclzz   1/1   Running   0   102s   <- criado pelo HPA
mural-api-94fcf86cb-r8bnf   1/1   Running   0   102s   <- criado pelo HPA
mural-api-94fcf86cb-w7dpb   1/1   Running   0   4m12s
mural-api-94fcf86cb-wmvxp   1/1   Running   0   102s   <- criado pelo HPA
```

Depois da janela de estabilização (60 s), o HPA volta para 2 réplicas. Para desligar o bônus: `terraform apply -var enable_hpa=false`.

## Problemas encontrados no caminho

- **Chart do Traefik 41.x**: o tipo do Service mudou para `service.spec.type`. Com a chave antiga (`service.type`), o Service ficava `LoadBalancer` com EXTERNAL-IP pendente para sempre, e o `helm_release` estourava o timeout.
- **`kind load` com CLI antigo**: kind v0.26 com nó `v1.33.1` falha com `failed to detect containerd snapshotter`. Use kind ≥ v0.29.
- **Check de smoke test no Terraform**: um bloco `check` com `data "http"` funcionava, mas fazia o plan mostrar uma leitura a cada execução (`0 to add` em vez de `No changes`). Saiu do Terraform e virou `make test`.
