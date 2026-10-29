variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "lgtm-demo"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the Gateway NLB and the EKS public API endpoint (your public IP, e.g. 203.0.113.4/32)"
  type        = string
}

variable "expected_account_id" {
  description = "AWS account ID this stack may be applied to (company account)"
  type        = string
  default     = "461485115270"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "node_instance_types" {
  description = "Instance types for the on-demand managed node group"
  type        = list(string)
  default     = ["t3.xlarge"]
}

variable "node_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count"
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.42.0.0/16"
}

variable "retention_days" {
  description = "Retention in days for logs, traces, metrics and S3 lifecycle expiry"
  type        = number
  default     = 7
}

variable "chart_versions" {
  description = "Pinned Helm chart versions"
  type        = map(string)
  default = {
    loki           = "20.0.2" # grafana-community repo (grafana/loki is deprecated). Loki 3.7.9
    tempo          = "3.2.1"  # grafana-community repo (grafana/tempo is deprecated). Tempo 3.1.1 monolithic, no Kafka needed
    mimir          = "6.2.2"  # grafana repo, mimir-distributed. Mimir 3.2.3, ingest storage (Kafka) disabled
    grafana        = "14.2.0" # grafana-community repo (grafana/grafana is deprecated). Grafana 13.3.0
    alloy          = "1.14.4" # grafana repo
    astronomy_shop = "0.42.6"
    envoy_gateway  = "1.9.3" # oci://docker.io/envoyproxy/gateway-helm, bundles Gateway API CRDs
    cert_manager   = "v1.21.3"
    kube_state     = "8.7.1"
  }
}

variable "tags" {
  description = "Organisation-mandated AWS tags applied to all resources via provider default_tags"
  type        = map(string)
  default     = {}
}
