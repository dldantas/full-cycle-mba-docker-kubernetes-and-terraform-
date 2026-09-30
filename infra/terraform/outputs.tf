output "url" {
  description = "Endereço do Mural no navegador."
  value       = local.app_url
}

output "cluster_name" {
  description = "Nome do cluster kind."
  value       = kind_cluster.this.name
}

output "kubeconfig_path" {
  description = "Kubeconfig gerado para o cluster (use com KUBECONFIG=... ou --kubeconfig)."
  value       = kind_cluster.this.kubeconfig_path
}

output "namespace" {
  description = "Namespace da aplicação."
  value       = kubernetes_namespace_v1.mural.metadata[0].name
}

output "images" {
  description = "Imagens construídas e carregadas no cluster."
  value       = local.image_refs
}

output "kubectl_hint" {
  description = "Comando para inspecionar a aplicação."
  value       = "kubectl --kubeconfig \"${kind_cluster.this.kubeconfig_path}\" -n ${kubernetes_namespace_v1.mural.metadata[0].name} get pods,svc,ingress,pvc,job"
}
