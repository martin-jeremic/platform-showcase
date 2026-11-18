{{/* Common labels */}}
{{- define "cluster-monitoring-agent.labels" -}}
app.kubernetes.io/name: cluster-monitoring-agent
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
=============================================================================
Alloy pipeline (Alloy config).

Single-OTLP-egress + mTLS model:
  - Collect metrics (scrape), logs (k8s API) and traces (OTLP receiver).
  - Bridge each into the OpenTelemetry pipeline.
  - Stamp the `cluster` label/attribute on every signal.
  - Export everything through ONE otelcol OTLP exporter to the hub, secured
    with a client certificate (mTLS). No per-backend endpoints, no OAuth2.
=============================================================================
*/}}
{{- define "cluster-monitoring-agent.alloyConfig" -}}
{{- $cluster := .Values.global.cluster -}}
{{- $http := eq .Values.hub.otlp.protocol "http" -}}
{{- $hubInput := ternary "otelcol.exporter.otlphttp.hub.input" "otelcol.exporter.otlp.hub.input" $http -}}
logging {
  level  = "info"
  format = "logfmt"
}

/////////////////////////// OTLP EGRESS (mTLS) ////////////////////////////
{{- if $http }}

otelcol.exporter.otlphttp "hub" {
  client {
    endpoint = {{ required "hub.otlp.endpoint is required" .Values.hub.otlp.endpoint | quote }}
    tls {
      ca_file              = "/etc/alloy/tls/ca.crt"
      cert_file            = "/etc/alloy/tls/client.crt"
      key_file             = "/etc/alloy/tls/client.key"
      insecure_skip_verify = {{ .Values.hub.otlp.insecureSkipVerify }}
    }
  }
}
{{- else }}

otelcol.exporter.otlp "hub" {
  client {
    endpoint = {{ required "hub.otlp.endpoint is required" .Values.hub.otlp.endpoint | quote }}
    tls {
      ca_file              = "/etc/alloy/tls/ca.crt"
      cert_file            = "/etc/alloy/tls/client.crt"
      key_file             = "/etc/alloy/tls/client.key"
      insecure_skip_verify = {{ .Values.hub.otlp.insecureSkipVerify }}
    }
  }
}
{{- end }}

otelcol.processor.batch "default" {
  output {
    metrics = [{{ $hubInput }}]
    logs    = [{{ $hubInput }}]
    traces  = [{{ $hubInput }}]
  }
}

// Stamp `cluster` on every signal so the central Grafana can tell clusters
// apart. metric->datapoint attr (becomes a Prometheus label at the hub),
// log->attr + Loki label hint, trace->span attr (searchable in Tempo).
otelcol.processor.transform "add_cluster" {
  error_mode = "ignore"
  metric_statements {
    context    = "datapoint"
    statements = [
      `set(attributes["cluster"], {{ $cluster | quote }})`,
    ]
  }
  log_statements {
    context    = "log"
    statements = [
      `set(attributes["cluster"], {{ $cluster | quote }})`,
      `set(attributes["loki.attribute.labels"], "cluster")`,
      // Derive a meaningful service.name (else OTLP -> Loki defaults to
      // "unknown_service"). loki.source.kubernetes carries these as log
      // attributes: prefer app.kubernetes.io/name, then container, then pod.
      `set(resource.attributes["service.name"], attributes["app"]) where attributes["app"] != nil and attributes["app"] != ""`,
      `set(resource.attributes["service.name"], attributes["container"]) where (resource.attributes["service.name"] == nil or resource.attributes["service.name"] == "") and attributes["container"] != nil and attributes["container"] != ""`,
      `set(resource.attributes["service.name"], attributes["pod"]) where (resource.attributes["service.name"] == nil or resource.attributes["service.name"] == "") and attributes["pod"] != nil`,
    ]
  }
  trace_statements {
    context    = "span"
    statements = [
      `set(attributes["cluster"], {{ $cluster | quote }})`,
    ]
  }
  output {
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
    traces  = [otelcol.processor.batch.default.input]
  }
}

{{- if .Values.metrics.enabled }}

/////////////////////////////// METRICS ///////////////////////////////

// Prometheus -> OTLP bridge. Scrapes below forward here.
otelcol.receiver.prometheus "metrics" {
  output {
    metrics = [otelcol.processor.transform.add_cluster.input]
  }
}

// ---- kubelet (node-level kubelet metrics) ----
discovery.kubernetes "nodes" {
  role = "node"
}

discovery.relabel "kubelet" {
  targets = discovery.kubernetes.nodes.targets
  rule {
    target_label = "__address__"
    replacement  = "kubernetes.default.svc.cluster.local:443"
  }
  rule {
    source_labels = ["__meta_kubernetes_node_name"]
    regex         = "(.+)"
    target_label  = "__metrics_path__"
    replacement   = "/api/v1/nodes/${1}/proxy/metrics"
  }
  rule {
    source_labels = ["__meta_kubernetes_node_name"]
    target_label  = "node"
  }
  // kubernetes-mixin dashboards + recording rules select kubelet metrics by
  // job="kubelet" and metrics_path="/metrics". Set these so this cluster's
  // series match (the actual scrape path stays the API-server proxy URL above).
  rule {
    target_label = "metrics_path"
    replacement  = "/metrics"
  }
}

prometheus.scrape "kubelet" {
  targets           = discovery.relabel.kubelet.output
  forward_to        = [otelcol.receiver.prometheus.metrics.receiver]
  job_name          = "kubelet"
  scheme            = "https"
  scrape_interval   = {{ .Values.metrics.scrapeInterval | quote }}
  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  tls_config {
    ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    insecure_skip_verify = true
  }
}

// ---- cAdvisor (per-container CPU / memory usage) ----
discovery.relabel "cadvisor" {
  targets = discovery.kubernetes.nodes.targets
  rule {
    target_label = "__address__"
    replacement  = "kubernetes.default.svc.cluster.local:443"
  }
  rule {
    source_labels = ["__meta_kubernetes_node_name"]
    regex         = "(.+)"
    target_label  = "__metrics_path__"
    replacement   = "/api/v1/nodes/${1}/proxy/metrics/cadvisor"
  }
  rule {
    source_labels = ["__meta_kubernetes_node_name"]
    target_label  = "node"
  }
  // kubernetes-mixin selects cAdvisor metrics by job="kubelet" AND
  // metrics_path="/metrics/cadvisor" (same job as kubelet, split by path).
  rule {
    target_label = "metrics_path"
    replacement  = "/metrics/cadvisor"
  }
}

prometheus.scrape "cadvisor" {
  targets           = discovery.relabel.cadvisor.output
  forward_to        = [otelcol.receiver.prometheus.metrics.receiver]
  job_name          = "kubelet"
  scheme            = "https"
  scrape_interval   = {{ .Values.metrics.scrapeInterval | quote }}
  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  tls_config {
    ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    insecure_skip_verify = true
  }
}
{{- if .Values.nodeExporter.enabled }}

// ---- node-exporter (host CPU / memory / disk / network) ----
discovery.kubernetes "node_exporter" {
  role = "pod"
  namespaces {
    names = [{{ .Release.Namespace | quote }}]
  }
  selectors {
    role  = "pod"
    label = "app.kubernetes.io/name=prometheus-node-exporter"
  }
}

discovery.relabel "node_exporter" {
  targets = discovery.kubernetes.node_exporter.targets
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "instance"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }
}

prometheus.scrape "node_exporter" {
  targets         = discovery.relabel.node_exporter.output
  forward_to      = [otelcol.receiver.prometheus.metrics.receiver]
  job_name        = "node-exporter"
  scrape_interval = {{ .Values.metrics.scrapeInterval | quote }}
}
{{- end }}
{{- if .Values.kubeStateMetrics.enabled }}

// ---- kube-state-metrics (Kubernetes object state) ----
prometheus.scrape "kube_state_metrics" {
  targets = [{
    "__address__" = {{ printf "%s.%s.svc.cluster.local:8080" .Values.kubeStateMetrics.serviceName .Release.Namespace | quote }},
  }]
  forward_to      = [otelcol.receiver.prometheus.metrics.receiver]
  job_name        = "kube-state-metrics"
  scrape_interval = {{ .Values.metrics.scrapeInterval | quote }}
}
{{- end }}
{{- if .Values.metrics.trivy.enabled }}

// ---- trivy (Trivy Operator security-report counts, trivy_*) ----
// A static target like kube-state-metrics above, and deliberately NOT the
// annotated-pods job below: that job stamps the scraped pod's own namespace as
// `namespace`, which would rename the label every trivy_* series carries -- the
// namespace of the SCANNED workload -- to exported_namespace. With no discovery
// labels the series reach the hub as the operator wrote them, the same series
// a ServiceMonitor with honorLabels gives on a cluster running its own
// Prometheus, so one dashboard reads both. The Service is headless (DNS answers
// with the pod IP), so the target is the container port 8080, not the
// Service port.
prometheus.scrape "trivy" {
  targets = [{
    "__address__" = {{ printf "%s.%s.svc.cluster.local:8080" .Values.metrics.trivy.serviceName .Values.metrics.trivy.namespace | quote }},
  }]
  forward_to      = [otelcol.receiver.prometheus.metrics.receiver]
  job_name        = "trivy"
  scrape_interval = {{ .Values.metrics.scrapeInterval | quote }}
}
{{- end }}
{{- if .Values.metrics.scrapeAnnotatedPods }}

// ---- application pods carrying prometheus.io/scrape annotations ----
discovery.kubernetes "annotated_pods" {
  role = "pod"
}

discovery.relabel "annotated_pods" {
  targets = discovery.kubernetes.annotated_pods.targets
  rule {
    source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
    regex         = "true"
    action        = "keep"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"]
    regex         = "(.+)"
    target_label  = "__metrics_path__"
  }
  rule {
    source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"]
    regex         = "([^:]+)(?::\\d+)?;(\\d+)"
    replacement   = "$1:$2"
    target_label  = "__address__"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }
}

prometheus.scrape "annotated_pods" {
  targets         = discovery.relabel.annotated_pods.output
  forward_to      = [otelcol.receiver.prometheus.metrics.receiver]
  job_name        = "integrations/annotated-pods"
  scrape_interval = {{ .Values.metrics.scrapeInterval | quote }}
}
{{- end }}
{{- if .Values.metrics.rabbitmq.enabled }}

// ---- RabbitMQ (rabbitmq_prometheus plugin) ----
// The broker pod carries no prometheus.io/* annotations and its Service does not
// publish the metrics port, so neither the annotated-pods scrape nor a Service
// target would find it. Discover the pod by label and scrape it directly on
// podIP:<port> at the per-object path (gives the per-queue `queue` label the
// RabbitMQ dashboard needs). Series flow through the same OTLP egress and get
// stamped cluster={{ $cluster }} like every other signal. The job label is
// metrics.rabbitmq.jobName: `rabbitmq`, the job the rabbitmq chart pins on its own
// ServiceMonitor, so the hub's rules/rabbitmq.yaml covers this cluster too.
discovery.kubernetes "rabbitmq" {
  role = "pod"
  namespaces {
    names = [{{ .Values.metrics.rabbitmq.namespace | quote }}]
  }
  selectors {
    role  = "pod"
    label = {{ .Values.metrics.rabbitmq.podLabelSelector | quote }}
  }
}

discovery.relabel "rabbitmq" {
  targets = discovery.kubernetes.rabbitmq.targets
  // Pin the scrape address to podIP:<metricsPort>. The metrics port is not a
  // declared containerPort, so the discovered target would otherwise be wrong.
  rule {
    source_labels = ["__meta_kubernetes_pod_ip"]
    regex         = "(.+)"
    replacement   = {{ printf "${1}:%v" .Values.metrics.rabbitmq.port | quote }}
    target_label  = "__address__"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }
}

prometheus.scrape "rabbitmq" {
  targets         = discovery.relabel.rabbitmq.output
  forward_to      = [otelcol.receiver.prometheus.metrics.receiver]
  job_name        = {{ .Values.metrics.rabbitmq.jobName | quote }}
  metrics_path    = {{ .Values.metrics.rabbitmq.path | quote }}
  scrape_interval = {{ .Values.metrics.scrapeInterval | quote }}
}
{{- end }}
{{- end }}{{/* end metrics.enabled */}}

{{- if .Values.logs.enabled }}

//////////////////////////////// LOGS /////////////////////////////////

// Loki -> OTLP bridge. The log source forwards here.
otelcol.receiver.loki "logs" {
  output {
    logs = [otelcol.processor.transform.add_cluster.input]
  }
}

// Pods on THIS node only. Every agent pod of the DaemonSet would otherwise tail
// every pod in the CLUSTER, ingesting each line once per node and multiplying the
// apiserver watch load. HOSTNAME is set to spec.nodeName by the Alloy chart's
// DaemonSet template.
discovery.kubernetes "log_pods" {
  role = "pod"

  selectors {
    role  = "pod"
    field = "spec.nodeName=" + sys.env("HOSTNAME")
  }
}

discovery.relabel "log_pods" {
  targets = discovery.kubernetes.log_pods.targets
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    target_label  = "app"
  }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.log_pods.output
  forward_to = [otelcol.receiver.loki.logs.receiver]
}
{{- end }}{{/* end logs.enabled */}}

{{- if .Values.traces.enabled }}

/////////////////////////////// TRACES ////////////////////////////////

// Receive OTLP from in-cluster apps. Accepts traces (and any OTLP metrics/logs
// apps choose to send) and routes them into the same pipeline.
otelcol.receiver.otlp "apps" {
  grpc {
    endpoint = "0.0.0.0:{{ .Values.traces.otlp.grpcPort }}"
  }
  http {
    endpoint = "0.0.0.0:{{ .Values.traces.otlp.httpPort }}"
  }
  output {
    metrics = [otelcol.processor.transform.add_cluster.input]
    logs    = [otelcol.processor.transform.add_cluster.input]
    traces  = [otelcol.processor.transform.add_cluster.input]
  }
}
{{- end }}{{/* end traces.enabled */}}
{{- end }}
