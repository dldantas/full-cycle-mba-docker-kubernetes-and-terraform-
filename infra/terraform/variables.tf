variable "cluster_name" {
  description = "Nome do cluster kind."
  type        = string
  default     = "mural"
}

variable "node_image" {
  description = "Imagem do nó kind (define a versão do Kubernetes)."
  type        = string
  default     = "kindest/node:v1.33.1"
}

variable "http_port" {
  description = "Porta do host mapeada para o entrypoint HTTP do Traefik."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "Porta do host mapeada para o entrypoint HTTPS do Traefik."
  type        = number
  default     = 443
}

variable "namespace" {
  description = "Namespace da aplicação."
  type        = string
  default     = "mural"
}

variable "ingress_host" {
  description = "Host do Ingress. *.localtest.me resolve para 127.0.0.1."
  type        = string
  default     = "mural.localtest.me"
}

variable "traefik_chart_version" {
  description = "Versão do chart do Traefik (fixada para reprodutibilidade)."
  type        = string
  default     = "41.6.0"
}

variable "enable_hpa" {
  description = "Instala o metrics-server e liga o HPA da API (bônus)."
  type        = bool
  default     = true
}

variable "metrics_server_chart_version" {
  description = "Versão do chart do metrics-server."
  type        = string
  default     = "3.14.0"
}

variable "api_replicas" {
  description = "Réplicas da API (mínimo do HPA quando enable_hpa = true)."
  type        = number
  default     = 2
}

variable "web_replicas" {
  description = "Réplicas do front."
  type        = number
  default     = 2
}

variable "db_user" {
  description = "Usuário do Postgres."
  type        = string
  default     = "mural"
}

variable "db_name" {
  description = "Nome do banco."
  type        = string
  default     = "mural"
}
