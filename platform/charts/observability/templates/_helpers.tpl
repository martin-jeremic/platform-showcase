{{/*
Common labels for any resources added directly by this umbrella chart.
Subchart resources use their own label helpers.
*/}}
{{- define "observability.labels" -}}
app.kubernetes.io/name: observability
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
The name the alloy SUBCHART will use for itself, recomputed here.

Why this exists: with `alloy.configMap.create: false` the subchart mounts a
ConfigMap called `alloy.config-map.name`, which — when `configMap.name` is unset
— is just `alloy.fullname`. That value is NOT passed through `tpl`, so it cannot
be written as a template in values.yaml, and hardcoding "observability-alloy"
there would duplicate something already derivable from the release name.

So instead of naming the ConfigMap by hand, this mirrors the subchart's own
fullname logic (alloy/templates/_helpers.tpl) against the SAME values the
subchart reads. Set `alloy.fullnameOverride` and both sides follow it.

Keep in step with the vendored alloy chart if that helper ever changes: a
mismatch is silent at render time and surfaces as an Alloy pod stuck in
ContainerCreating on a ConfigMap that does not exist.
*/}}
{{- define "observability.alloyFullname" -}}
{{- $sub := .Values.alloy | default dict -}}
{{- if $sub.fullnameOverride -}}
{{- $sub.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "alloy" $sub.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Alloy pipeline (River) for collecting this cluster's pod logs into the local Loki.

Adapted from cluster-monitoring-agent's helper, with three deliberate differences:
  1. Reads log FILES on the node (loki.source.file) instead of the Kubernetes API
     (loki.source.kubernetes). Grafana's own reference notes the API source "uses
     more network traffic and CPU consumption of Kubelets". File-based also keeps a positions
     file, so a pod restart resumes rather than re-reading the node's history.
  2. A spec.nodeName field selector. THIS IS NOT OPTIONAL on a DaemonSet: without
     it every Alloy pod tails every pod in the CLUSTER, so on a 2-node cluster
     each line is ingested twice and the apiserver watch load doubles. (The agent
     chart reads logs through the API instead and filters the same way.)
  3. Writes straight to the in-cluster Loki, not an mTLS OTLP egress to the hub.
*/}}
{{- define "observability.alloyConfig" -}}
{{- $p := .Values.alloyPipeline -}}
{{- if not $p.cluster }}{{ fail "alloyPipeline.cluster is required when components.alloy is true — it is the `cluster` label stamped on every log stream" }}{{ end -}}
{{- if not $p.tenant }}{{ fail "alloyPipeline.tenant is required when components.alloy is true — Loki has auth_enabled, so a push with no X-Scope-OrgID is rejected with 401 'no org id'" }}{{ end -}}
{{- if not $p.lokiPushUrl }}{{ fail "alloyPipeline.lokiPushUrl is required when components.alloy is true" }}{{ end -}}
logging {
  level  = {{ $p.logLevel | quote }}
  format = "logfmt"
}

// Pods on THIS node only. HOSTNAME is set to spec.nodeName by the Alloy chart's
// own DaemonSet template, so no extraEnv is needed to resolve it.
discovery.kubernetes "pod_logs" {
  role = "pod"

  selectors {
    role  = "pod"
    field = "spec.nodeName=" + sys.env("HOSTNAME")
  }
}

discovery.relabel "pod_logs" {
  targets = discovery.kubernetes.pod_logs.targets

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
    source_labels = ["__meta_kubernetes_node_name"]
    target_label  = "node"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    target_label  = "app"
  }

  // Kubelet lays containerd logs out as
  //     /var/log/pods/<namespace>_<pod>_<uid>/<container>/<n>.log
  // The two source labels are joined by `separator`, and with the default regex
  // `(.*)` the WHOLE joined "<uid>/<container>" string lands in $1 — which is why
  // one $1 produces two path segments below. Non-obvious, but it is the upstream
  // Grafana idiom; do not "fix" it into $1/$2 without also setting an explicit regex.
  rule {
    source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
    separator     = "/"
    action        = "replace"
    replacement   = "/var/log/pods/*$1/*.log"
    target_label  = "__path__"
  }
}

local.file_match "pod_logs" {
  path_targets = discovery.relabel.pod_logs.output
}

loki.source.file "pod_logs" {
  targets    = local.file_match.pod_logs.targets
  forward_to = [loki.process.pod_logs.receiver]
}

loki.process "pod_logs" {
  // containerd writes each line as "<ts> <stream> <F|P> <message>". Without this
  // stage Grafana shows every line prefixed "stdout F" and timestamps the entry
  // at read time instead of emit time.
  stage.cri {}
{{- if $p.parseLogContract }}

  // The application log contract (alloyPipeline.parseLogContract), emitted
  // identically by the .NET services and the Python services through their
  // shared logging libraries (services/ in this repository). The field set MUST stay
  // identical to observability-ingest/templates/_helpers.tpl (loki.process
  // "set_tenant", step 2), which gives the spokes' logs the same schema on the
  // hub: the LogQL rules in observability-log-rules filter on these names on
  // every tenant. tools/check-observability.sh fails when the two differ.
  //
  // Guarded on "line starts with {" so plain-text producers pass through
  // untouched rather than failing a JSON parse on every line. The selector reads
  // `namespace`, not `cluster`: cluster is an external label added by
  // loki.write, after this stage.
  stage.match {
    selector = "{namespace=~\".+\"} |~ \"^\\\\{\""

    stage.json {
      expressions = {
        level          = "",
        logger         = "",
        trace_id       = "",
        span_id        = "",
        correlation_id = "",
        http_method    = "",
        http_path      = "",
        http_status    = "",
        duration_ms    = "",
        exception_type = "",
      }
    }

    // Bounded value set -> safe to index.
    stage.labels {
      values = {
        level = "",
      }
    }

    // Unbounded or high cardinality -> structured metadata. http_path in
    // particular would otherwise create a stream per URL. `exception` (the stack
    // trace) is deliberately NOT promoted: it routinely exceeds
    // max_structured_metadata_size (64KB); it stays in the line body.
    stage.structured_metadata {
      values = {
        logger         = "",
        trace_id       = "",
        span_id        = "",
        correlation_id = "",
        http_method    = "",
        http_path      = "",
        http_status    = "",
        duration_ms    = "",
        exception_type = "",
      }
    }
  }
{{- end }}

  forward_to = [loki.write.local.receiver]
}

loki.write "local" {
  endpoint {
    url       = {{ $p.lokiPushUrl | quote }}
    tenant_id = {{ $p.tenant | quote }}
  }

  external_labels = {
    cluster = {{ $p.cluster | quote }},
  }
}
{{- end -}}

{{/*
==============================================================================
Alerting helpers (2.1.0). Used by templates/alertmanager-config.yaml,
templates/alertmanager-secretproviderclass.yaml and templates/assertions.yaml.

Everything below DERIVES a value from the place it is already declared instead
of asking for it a second time. Each source is named, and each helper `fail`s
when the source is missing, so a broken link shows up as a render error (Argo
ComparisonError) rather than as a notification that quietly links nowhere.
==============================================================================
*/}}

{{/*
The SecretProviderClass that carries the Alertmanager receiver credentials.
The CSI volume in the cluster values file must reference exactly this name;
observability.alertmanagerKvMountPath checks that it does.
*/}}
{{- define "observability.alertmanagerKvName" -}}
alertmanager-kv
{{- end -}}

{{/*
File name of a Teams webhook URL inside the Key Vault mount -- also the vault
object's name after "<objectPrefix>--". Called with the audience name, or with
"" for the default destination (notifications.graph):
  ""        -> teams-webhook-url
  product-a -> product-a-teams-webhook-url
The config (webhook_url_file) and the SecretProviderClass (objectName /
objectAlias) both call this, so the file a receiver reads is always the file
that is mounted. The alerting stack in infra/ writes the vault objects
under the same names.
*/}}
{{- define "observability.teamsWebhookFile" -}}
{{- if . }}{{ . }}-{{ end }}teams-webhook-url
{{- end -}}

{{/*
Public Grafana root for the Silence / Logs links, read from
kubePromStack.grafana."grafana.ini".server.root_url -- the same value Grafana
itself serves from. An earlier lineage of this chart kept it as a second literal in a
cluster template file because kube-prometheus-stack renders templateFiles
without tpl; this chart renders the Alertmanager config itself, so it can read
it directly.
*/}}
{{- define "observability.grafanaRootUrl" -}}
{{- $ini := index .Values.kubePromStack.grafana "grafana.ini" | default dict -}}
{{- $server := index $ini "server" | default dict -}}
{{- required "kubePromStack.grafana.\"grafana.ini\".server.root_url is required: the alert notification links are built from it" (index $server "root_url") | trimSuffix "/" -}}
{{- end -}}

{{/*
uid of the Loki datasource the Logs link opens Explore against, read from
kubePromStack.grafana.additionalDataSources. The first type: loki entry wins.
*/}}
{{- define "observability.lokiDatasourceUid" -}}
{{- $uid := "" -}}
{{- range (.Values.kubePromStack.grafana.additionalDataSources | default list) -}}
{{- if and (not $uid) (eq (.type | default "") "loki") -}}
{{- $uid = .uid | default "" -}}
{{- end -}}
{{- end -}}
{{- if not $uid -}}
{{- fail "kubePromStack.grafana.additionalDataSources has no type: loki entry with a uid: the Logs link in alert notifications opens Explore against it" -}}
{{- end -}}
{{- $uid -}}
{{- end -}}

{{/*
Name of the Alertmanager datasource the Silence link opens, read from the
kube-prometheus-stack sidecar default (grafana.sidecar.datasources.alertmanager,
which provisions it). An earlier lineage hardcoded "Alertmanager" in the link
and carried a comment asking that the two be changed together.
*/}}
{{- define "observability.alertmanagerDatasourceName" -}}
{{- $am := .Values.kubePromStack.grafana.sidecar.datasources.alertmanager | default dict -}}
{{- if not $am.enabled -}}
{{- fail "kubePromStack.grafana.sidecar.datasources.alertmanager.enabled is false: the Silence link in alert notifications needs Grafana's Alertmanager datasource (Alertmanager itself is not exposed)" -}}
{{- end -}}
{{- required "kubePromStack.grafana.sidecar.datasources.alertmanager.name is required" $am.name -}}
{{- end -}}

{{/*
The one template file this chart DERIVES rather than ships: the three facts the
link templates in alertmanager/notifications.tmpl need, each defined
exactly once. There is no fallback define anywhere, so the lexical load order of
*.tmpl files is irrelevant here.

The three values are spliced into URLs without urlquery (an Alertmanager
template cannot pipe another template's output), so each is checked against a
URL-safe character set.
*/}}
{{- define "observability.alertmanagerDerivedTmpl" -}}
{{- $root := include "observability.grafanaRootUrl" . -}}
{{- $loki := include "observability.lokiDatasourceUid" . -}}
{{- $amds := include "observability.alertmanagerDatasourceName" . -}}
{{- if not (regexMatch "^https?://[A-Za-z0-9._~:/-]+$" $root) -}}
{{- fail (printf "grafana.ini server.root_url %q contains characters that would need URL-escaping in alert links" $root) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._~-]+$" $loki) -}}
{{- fail (printf "Loki datasource uid %q is not URL-safe" $loki) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._~-]+$" $amds) -}}
{{- fail (printf "Alertmanager datasource name %q is not URL-safe" $amds) -}}
{{- end -}}
{{- printf "{{/* DERIVED by the observability chart (templates/_helpers.tpl). Do not hand-edit: change the source values. */}}\n" -}}
{{- printf "{{ define \"platform.grafanaBase\" }}%s{{ end }}\n" $root -}}
{{- printf "{{ define \"platform.lokiUid\" }}%s{{ end }}\n" $loki -}}
{{- printf "{{ define \"platform.alertmanagerDatasource\" }}%s{{ end }}\n" $amds -}}
{{- end -}}

{{/*
Mount path of the Key Vault CSI volume inside the Alertmanager pod, derived from
kubePromStack.alertmanager.alertmanagerSpec.volumes / volumeMounts (cluster
values file). The credential file paths in the rendered config are built from
it, so they cannot disagree with the mount. Fails, naming the fix, when:
  - no CSI volume references the SecretProviderClass;
  - authMode workloadIdentity lacks the Alertmanager ServiceAccount client-id
    annotation or the azure.workload.identity/use pod label;
  - authMode servicePrincipal has no nodePublishSecretRef (the mount fails with
    "fetching NodePublishSecretRef ... failed" and the pod stays in
    ContainerCreating);
  - any other authMode HAS one (the driver then prefers the static credential
    and silently ignores the managed identity);
  - no volumeMount mounts that volume.
*/}}
{{- define "observability.alertmanagerKvMountPath" -}}
{{- $spc := include "observability.alertmanagerKvName" . -}}
{{- $spec := .Values.kubePromStack.alertmanager.alertmanagerSpec -}}
{{- $vol := dict -}}
{{- range ($spec.volumes | default list) -}}
{{- if and .csi (eq (dig "volumeAttributes" "secretProviderClass" "" .csi) $spc) -}}
{{- $vol = . -}}
{{- end -}}
{{- end -}}
{{- if not $vol.name -}}
{{- fail (printf "notifications.enabled is true, but kubePromStack.alertmanager.alertmanagerSpec.volumes has no CSI volume with volumeAttributes.secretProviderClass: %s. Add it (and its volumeMount) in this cluster's values file; the notifications block in values.yaml shows the shape." $spc) -}}
{{- end -}}
{{- $ref := dig "nodePublishSecretRef" "name" "" $vol.csi -}}
{{- $mode := .Values.notifications.keyVault.authMode -}}
{{- if eq $mode "workloadIdentity" -}}
{{- $am := .Values.kubePromStack.alertmanager -}}
{{- $saAnn := ((($am.serviceAccount | default dict).annotations) | default dict) -}}
{{- if not (index $saAnn "azure.workload.identity/client-id") -}}
{{- fail "notifications.keyVault.authMode is workloadIdentity, but kubePromStack.alertmanager.serviceAccount.annotations has no azure.workload.identity/client-id: the SecretProviderClass would have no identity to exchange a token for" -}}
{{- end -}}
{{- $podLabels := (($spec.podMetadata | default dict).labels | default dict) -}}
{{- if ne (toString (index $podLabels "azure.workload.identity/use" | default "")) "true" -}}
{{- fail "notifications.keyVault.authMode is workloadIdentity, but kubePromStack.alertmanager.alertmanagerSpec.podMetadata.labels has no azure.workload.identity/use: \"true\". Without the label the webhook never projects the token, and the mount fails although the ServiceAccount looks right" -}}
{{- end -}}
{{- end -}}
{{- if eq $mode "servicePrincipal" -}}
{{- if not $ref -}}
{{- fail (printf "notifications.keyVault.authMode is servicePrincipal, but volume %s has no csi.nodePublishSecretRef.name (the per-namespace secrets-store-creds Secret)" $vol.name) -}}
{{- end -}}
{{- else if $ref -}}
{{- fail (printf "volume %s sets csi.nodePublishSecretRef, but notifications.keyVault.authMode is %s: the driver would use the static credential and ignore the identity. Remove nodePublishSecretRef." $vol.name $mode) -}}
{{- end -}}
{{- $mount := "" -}}
{{- range ($spec.volumeMounts | default list) -}}
{{- if eq .name $vol.name -}}
{{- $mount = .mountPath -}}
{{- end -}}
{{- end -}}
{{- if not $mount -}}
{{- fail (printf "kubePromStack.alertmanager.alertmanagerSpec.volumeMounts does not mount volume %s" $vol.name) -}}
{{- end -}}
{{- $mount | trimSuffix "/" -}}
{{- end -}}
