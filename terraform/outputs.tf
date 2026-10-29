output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

locals {
  nlb_hostname = try(data.kubernetes_service_v1.gateway_nlb.status[0].load_balancer[0].ingress[0].hostname, "")
}

output "gateway_nlb_hostname" {
  description = "Hostname of the Gateway NLB (empty if not yet provisioned; run apply/refresh again)"
  value       = local.nlb_hostname
}

output "grafana_url" {
  description = "Grafana URL via the Gateway (self-signed CA, browser warning expected). Empty until the NLB hostname exists."
  value       = local.nlb_hostname == "" ? "" : "https://${local.nlb_hostname}/grafana"
}

output "shop_url" {
  description = "Astronomy Shop storefront URL via the Gateway. Empty until the NLB hostname exists."
  value       = local.nlb_hostname == "" ? "" : "https://${local.nlb_hostname}/"
}

output "grafana_admin_password" {
  description = "Grafana admin password (retrieve with: terraform output -raw grafana_admin_password)"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "s3_buckets" {
  description = "S3 buckets for Loki, Tempo and Mimir"
  value       = { for k, b in aws_s3_bucket.lgtm : k => b.id }
}

output "kubeconfig_command" {
  description = "Command to configure kubectl for the cluster"
  value       = "aws eks update-kubeconfig --profile company --region ${var.region} --name ${module.eks.cluster_name}"
}

output "access_note" {
  description = "How to reach the demo and trust the CA"
  value       = "Only ${var.allowed_cidr} can reach the NLB. TLS is signed by a self-signed demo CA, so expect a browser warning. To trust it: kubectl get secret lgtm-ca-key-pair -n cert-manager -o jsonpath='{.data.ca\\.crt}' | base64 -d > lgtm-ca.crt, then add it to your trust store (or use curl --cacert). Grafana user admin, password: terraform output -raw grafana_admin_password."
}
