locals {
  config_dir = "${path.module}/../config"

  grafana_datasources_file = "${local.config_dir}/grafana/datasources.yaml"
  grafana_alerting_file    = "${local.config_dir}/grafana/alerting/rules.yaml"
  alloy_config_file        = "${local.config_dir}/alloy/config.alloy"
  shop_values_file         = "${local.config_dir}/astronomy-shop/values.yaml"

  grafana_dashboard_files = fileset("${local.config_dir}/grafana/dashboards", "*.json")

  retention_hours = "${var.retention_days * 24}h"
  storage_class   = kubernetes_storage_class_v1.gp3.metadata[0].name
}

# Soft check: warn (do not fail) if Agent 2 config files are missing at apply time.
check "config_files_present" {
  assert {
    condition = alltrue([
      fileexists(local.grafana_datasources_file),
      fileexists(local.grafana_alerting_file),
      fileexists(local.alloy_config_file),
      fileexists(local.shop_values_file),
      length(local.grafana_dashboard_files) > 0,
    ])
    error_message = "One or more files under ./config are missing (datasources, alerting rules, alloy config, astronomy-shop values or dashboards). The stack will deploy without them."
  }
}

resource "kubernetes_namespace_v1" "lgtm" {
  metadata {
    name = local.lgtm_namespace
  }
  depends_on = [module.eks]
}

resource "kubernetes_namespace_v1" "shop" {
  metadata {
    name = "astronomy-shop"
  }
  depends_on = [module.eks]
}

# ---------------------------------------------------------------- Grafana admin secret
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.lgtm.metadata[0].name
  }
  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  }
}

# ---------------------------------------------------------------- Loki / Tempo / Mimir
resource "helm_release" "loki" {
  name       = "loki"
  namespace  = kubernetes_namespace_v1.lgtm.metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = var.chart_versions.loki
  timeout    = 900

  values = [templatefile("${path.module}/templates/loki-values.yaml.tftpl", {
    bucket        = aws_s3_bucket.lgtm["loki"].id
    region        = var.region
    role_arn      = aws_iam_role.s3["loki"].arn
    retention     = local.retention_hours
    storage_class = local.storage_class
  })]

  depends_on = [aws_iam_role_policy.s3]
}

resource "helm_release" "tempo" {
  name       = "tempo"
  namespace  = kubernetes_namespace_v1.lgtm.metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "tempo"
  version    = var.chart_versions.tempo
  timeout    = 900

  values = [templatefile("${path.module}/templates/tempo-values.yaml.tftpl", {
    bucket        = aws_s3_bucket.lgtm["tempo"].id
    region        = var.region
    role_arn      = aws_iam_role.s3["tempo"].arn
    retention     = local.retention_hours
    storage_class = local.storage_class
  })]

  depends_on = [aws_iam_role_policy.s3]
}

resource "helm_release" "mimir" {
  name       = "mimir"
  namespace  = kubernetes_namespace_v1.lgtm.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "mimir-distributed"
  version    = var.chart_versions.mimir
  timeout    = 900

  values = [templatefile("${path.module}/templates/mimir-values.yaml.tftpl", {
    bucket        = aws_s3_bucket.lgtm["mimir"].id
    region        = var.region
    role_arn      = aws_iam_role.s3["mimir"].arn
    retention     = local.retention_hours
    storage_class = local.storage_class
  })]

  depends_on = [aws_iam_role_policy.s3]
}

# ---------------------------------------------------------------- Grafana provisioning
resource "kubernetes_config_map_v1" "grafana_datasources" {
  count = fileexists(local.grafana_datasources_file) ? 1 : 0
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace_v1.lgtm.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }
  data = {
    "datasources.yaml" = (fileexists(local.grafana_datasources_file) ? file(local.grafana_datasources_file) : "")
  }
}

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  for_each = local.grafana_dashboard_files
  metadata {
    name      = "grafana-dashboard-${replace(lower(trimsuffix(each.value, ".json")), "/[^a-z0-9-]/", "-")}"
    namespace = kubernetes_namespace_v1.lgtm.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    (each.value) = file("${local.config_dir}/grafana/dashboards/${each.value}")
  }
}

resource "kubernetes_config_map_v1" "grafana_alerting" {
  count = fileexists(local.grafana_alerting_file) ? 1 : 0
  metadata {
    name      = "grafana-alerting"
    namespace = kubernetes_namespace_v1.lgtm.metadata[0].name
    labels    = { grafana_alert = "1" }
  }
  data = {
    "rules.yaml" = (fileexists(local.grafana_alerting_file) ? file(local.grafana_alerting_file) : "")
  }
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = kubernetes_namespace_v1.lgtm.metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = var.chart_versions.grafana
  timeout    = 600

  values = [templatefile("${path.module}/templates/grafana-values.yaml.tftpl", {
    admin_secret  = kubernetes_secret_v1.grafana_admin.metadata[0].name
    namespace     = kubernetes_namespace_v1.lgtm.metadata[0].name
    storage_class = local.storage_class
  })]

  depends_on = [
    kubernetes_config_map_v1.grafana_datasources,
    kubernetes_config_map_v1.grafana_dashboards,
    kubernetes_config_map_v1.grafana_alerting,
    helm_release.loki,
    helm_release.tempo,
    helm_release.mimir,
  ]
}

# ---------------------------------------------------------------- Alloy
resource "kubernetes_config_map_v1" "alloy" {
  count = fileexists(local.alloy_config_file) ? 1 : 0
  metadata {
    name      = "alloy-config"
    namespace = kubernetes_namespace_v1.lgtm.metadata[0].name
  }
  data = {
    "config.alloy" = (fileexists(local.alloy_config_file) ? file(local.alloy_config_file) : "")
  }
}

resource "helm_release" "alloy" {
  name       = "alloy"
  namespace  = kubernetes_namespace_v1.lgtm.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.chart_versions.alloy
  timeout    = 600

  values = [yamlencode({
    controller = {
      type     = "deployment"
      replicas = 1
    }
    alloy = {
      configMap = {
        create = false
        name   = "alloy-config"
        key    = "config.alloy"
      }
      extraPorts = [
        { name = "otlp-grpc", port = 4317, targetPort = 4317, protocol = "TCP" },
        { name = "otlp-http", port = 4318, targetPort = 4318, protocol = "TCP" },
      ]
    }
  })]

  # Alloy ships to Loki, Tempo and Mimir; start it after they exist.
  depends_on = [
    kubernetes_config_map_v1.alloy,
    helm_release.loki,
    helm_release.tempo,
    helm_release.mimir,
  ]
}

# ---------------------------------------------------------------- Astronomy Shop
resource "helm_release" "astronomy_shop" {
  name       = "astronomy-shop"
  namespace  = kubernetes_namespace_v1.shop.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-demo"
  version    = var.chart_versions.astronomy_shop
  timeout    = 900

  values = fileexists(local.shop_values_file) ? [(fileexists(local.shop_values_file) ? file(local.shop_values_file) : "")] : []

  depends_on = [helm_release.alloy]
}
