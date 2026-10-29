# Single public entry point: Envoy Gateway (one Gateway, one NLB), TLS from cert-manager
# (Let's Encrypt STAGING, DNS-01 via Route53/IRSA), DNS from external-dns.
#
# Gateway API CRDs are installed by the Envoy Gateway chart (crds.enabled=true). CRD-backed
# resources (EnvoyProxy, Gateway, ClusterIssuer, Certificate, HTTPRoute) are shipped as local
# Helm charts so `terraform plan` does not need CRDs to exist (unlike kubernetes_manifest).

locals {
  nlb_service_name  = "gateway-nlb"
  gateway_namespace = "gateway"
  envoy_namespace   = "envoy-gateway-system"
}

resource "kubernetes_namespace_v1" "gateway" {
  metadata {
    name = local.gateway_namespace
  }
  depends_on = [module.eks]
}

resource "helm_release" "envoy_gateway" {
  name             = "envoy-gateway"
  namespace        = local.envoy_namespace
  create_namespace = true
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = var.chart_versions.envoy_gateway
  timeout          = 600

  values = [yamlencode({
    crds = { enabled = true }
  })]

  # Destroyed only after the drain delay so the controller can remove the Gateway's NLB.
  depends_on = [module.eks]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.chart_versions.cert_manager
  timeout          = 600

  values = [yamlencode({
    crds = { enabled = true }
  })]

  depends_on = [module.eks]
}

resource "helm_release" "edge" {
  name      = "edge"
  namespace = kubernetes_namespace_v1.gateway.metadata[0].name
  chart     = "${path.module}/charts/edge"
  timeout   = 300
  wait      = false # do not block apply on Gateway/NLB or certificate readiness

  values = [yamlencode({
    gatewayNamespace = local.gateway_namespace
    nlbServiceName   = local.nlb_service_name
    allowedCidr      = var.allowed_cidr
    region           = var.region
    routeNamespaces  = [local.lgtm_namespace, "astronomy-shop"]
  })]

  depends_on = [time_sleep.gateway_drain]
}

resource "helm_release" "routes" {
  name      = "routes"
  namespace = kubernetes_namespace_v1.gateway.metadata[0].name
  chart     = "${path.module}/charts/routes"
  timeout   = 300
  wait      = false

  values = [yamlencode({
    gatewayNamespace = local.gateway_namespace
    grafanaNamespace = local.lgtm_namespace
    shopNamespace    = "astronomy-shop"
  })]

  depends_on = [helm_release.edge, helm_release.grafana, helm_release.astronomy_shop]
}

# Destroy ordering: routes and edge (Gateway) are destroyed first, then this resource waits
# 120s so the Envoy Gateway controller deletes the proxy Service/NLB, and only then are Envoy
# Gateway and cert-manager uninstalled (they are its dependencies). EKS (and so the VPC
# subnets and the GuardDuty cleanup provisioner) are destroyed after all of that.
resource "time_sleep" "gateway_drain" {
  destroy_duration = "120s"
  depends_on       = [helm_release.envoy_gateway, helm_release.cert_manager]
}

# Gives the NLB time to be provisioned so the hostname outputs are usually populated on first apply.
resource "time_sleep" "nlb_provision" {
  create_duration = "120s"
  depends_on      = [helm_release.edge, helm_release.routes]
}

data "kubernetes_service_v1" "gateway_nlb" {
  metadata {
    name      = local.nlb_service_name
    namespace = local.envoy_namespace
  }
  depends_on = [time_sleep.nlb_provision]
}

# ---------------------------------------------------------------- cluster metrics support
resource "helm_release" "kube_state_metrics" {
  name       = "kube-state-metrics"
  namespace  = kubernetes_namespace_v1.lgtm.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = var.chart_versions.kube_state
  timeout    = 600
}

# Alloy scrapes cadvisor through the API server node proxy (not in the Alloy chart's default RBAC).
resource "kubernetes_cluster_role_v1" "alloy_nodes_proxy" {
  metadata {
    name = "alloy-nodes-proxy"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes/proxy", "nodes/metrics"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "alloy_nodes_proxy" {
  metadata {
    name = "alloy-nodes-proxy"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.alloy_nodes_proxy.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "alloy"
    namespace = local.lgtm_namespace
  }
}
