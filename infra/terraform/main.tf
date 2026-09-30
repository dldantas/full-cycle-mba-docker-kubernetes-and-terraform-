# Maestro: cluster kind -> imagens -> Traefik (+ metrics-server) -> namespace -> chart do Mural.
# Um `terraform apply` sai do zero até o Mural respondendo; o segundo apply não muda
# nada; `terraform destroy` apaga o cluster (e com ele tudo o que rodava dentro).

locals {
  repo_root       = abspath("${path.module}/../..")
  chart_path      = abspath("${path.module}/../helm/mural")
  kubeconfig_path = abspath("${path.module}/.kube/${var.cluster_name}-config")

  # Portas do nó kind onde o Traefik escuta (NodePort) e que o kind expõe no host.
  traefik_node_ports = { web = 30080, websecure = 30443 }

  # Convenção: app/<chave> é o contexto e app/docker/<chave>.Dockerfile o Dockerfile.
  images = {
    for k in ["api", "web"] : k => {
      repository = "mural-${k}"
      context    = "${local.repo_root}/app/${k}"
      dockerfile = "${local.repo_root}/app/docker/${k}.Dockerfile"
    }
  }

  # Tag = hash do conteúdo (Dockerfile + contexto). Código igual -> tag igual ->
  # nada rebuilda nem reimplanta (idempotência). Código mudou -> tag nova ->
  # rebuild + kind load + rollout, sem precisar de "latest".
  image_tags = {
    for k, img in local.images : k => substr(sha1(join("", concat(
      [filesha1(img.dockerfile)],
      [for f in sort(fileset(img.context, "**")) : filesha1("${img.context}/${f}")]
    ))), 0, 12)
  }
  image_refs = { for k, img in local.images : k => "${img.repository}:${local.image_tags[k]}" }

  app_url = var.http_port == 80 ? "http://${var.ingress_host}" : "http://${var.ingress_host}:${var.http_port}"
}

# ---------------------------------------------------------------- cluster kind

resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = var.node_image
  kubeconfig_path = local.kubeconfig_path
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # ingress-ready=true: o Traefik é agendado neste nó (nodeSelector).
      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]

      # host:80/443 -> nó:30080/30443 (NodePorts do Traefik).
      extra_port_mappings {
        container_port = local.traefik_node_ports.web
        host_port      = var.http_port
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = local.traefik_node_ports.websecure
        host_port      = var.https_port
        protocol       = "TCP"
      }
    }
  }
}

# ---------------------------------------------------------------- imagens

# Build local + `kind load docker-image`. Os triggers só mudam quando o código
# muda (tag) ou o cluster é recriado — fora isso, nada roda de novo.
resource "terraform_data" "image" {
  for_each = local.images

  triggers_replace = {
    ref     = local.image_refs[each.key]
    cluster = kind_cluster.this.id
  }

  input = {
    ref = local.image_refs[each.key]
  }

  # Caminhos relativos à raiz do repo e sem aspas: o mesmo comando roda em
  # /bin/sh (Linux/macOS) e em cmd.exe (Windows).
  provisioner "local-exec" {
    working_dir = local.repo_root
    command     = "docker build -t ${local.image_refs[each.key]} -f app/docker/${each.key}.Dockerfile app/${each.key} && kind load docker-image ${local.image_refs[each.key]} --name ${kind_cluster.this.name}"
  }

  # Não deixa imagens órfãs no Docker local quando a tag é substituída ou no destroy.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "docker image rm ${self.input.ref}"
  }
}

# ---------------------------------------------------------------- ingress controller

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [yamlencode({
    # NodePort fixo + extraPortMappings do kind = Traefik acessível em localhost:80.
    service = { spec = { type = "NodePort" } }
    ports = {
      web       = { nodePort = local.traefik_node_ports.web }
      websecure = { nodePort = local.traefik_node_ports.websecure }
    }
    nodeSelector = { "ingress-ready" = "true" }
    tolerations = [{
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
    ingressClass = { enabled = true, isDefaultClass = true }
    ingressRoute = { dashboard = { enabled = false } }
  })]
}

# ---------------------------------------------------------------- metrics-server (bônus HPA)

resource "helm_release" "metrics_server" {
  count = var.enable_hpa ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 300

  # O kubelet do kind usa certificado autoassinado.
  values = [yamlencode({ args = ["--kubelet-insecure-tls"] })]
}

# ---------------------------------------------------------------- aplicação

resource "kubernetes_namespace_v1" "mural" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of" = "mural"
    }
  }
}

# Senha do banco gerada e guardada no state: estável entre applies (idempotente)
# e nunca escrita em arquivo versionado. Sem caracteres especiais para ir limpa
# na DATABASE_URL.
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "helm_release" "mural" {
  name      = "mural"
  chart     = local.chart_path
  namespace = kubernetes_namespace_v1.mural.metadata[0].name

  # wait = false é proposital: com --wait o Helm espera todos os Deployments
  # ficarem Ready ANTES de rodar hooks post-install, mas a API só fica Ready
  # DEPOIS da migração (que é o hook) -> deadlock. Sem --wait, o Helm aplica os
  # recursos e bloqueia no hook do Job até a migração terminar com sucesso
  # (hooks sempre são aguardados), então o apply só retorna com o schema pronto.
  wait    = false
  timeout = 600

  values = [yamlencode({
    database = {
      user = var.db_user
      name = var.db_name
    }
    api = {
      image       = { repository = local.images.api.repository, tag = local.image_tags.api }
      replicas    = var.api_replicas
      autoscaling = { enabled = var.enable_hpa, minReplicas = var.api_replicas }
    }
    web = {
      image    = { repository = local.images.web.repository, tag = local.image_tags.web }
      replicas = var.web_replicas
    }
    ingress = {
      className = "traefik"
      host      = var.ingress_host
    }
  })]

  set_sensitive = [{
    name  = "database.password"
    value = random_password.db.result
  }]

  depends_on = [
    terraform_data.image,
    helm_release.traefik,
    helm_release.metrics_server,
  ]
}
