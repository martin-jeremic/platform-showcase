{{/* Common labels */}}
{{- define "observability-ingest.labels" -}}
app.kubernetes.io/name: observability-ingest
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{/* Alloy component labels allow letters, digits and underscores only:
     product-a-stage -> product_a_stage. */}}
{{- define "observability-ingest.alloyId" -}}
{{- . | replace "-" "_" | replace "." "_" -}}
{{- end -}}

{{/*
=============================================================================
Alloy gateway pipeline.

Receive OTLP (mTLS) from spokes -> fan out to Prometheus (remote_write),
Loki (push) and Tempo (OTLP), all in-cluster. Tenant header per tenancy.*.
=============================================================================
*/}}
{{- define "observability-ingest.alloyConfig" -}}
{{/* Tenant routing (X-Scope-OrgID), active only when tenancy.enabled. Two modes:
       dynamic -> the tenant is the `cluster` each spoke's agent stamps on its
                  signals. Logs read it from the stream label (stage.tenant).
                  Traces get one filter + Tempo exporter per spokeClients entry,
                  because Alloy cannot route a trace's tenant by attribute.
                  Correct for any number of spokes.
       static  -> one staticTenant header for every spoke (legacy / single-spoke).
     Metrics stay header-less in dynamic mode (shared Prometheus; isolation deferred). */}}
{{- $tenant := "" -}}
{{- $dynamic := false -}}
{{- $mode := .Values.tenancy.mode | default "static" -}}
{{- if .Values.tenancy.enabled -}}
{{-   if eq $mode "dynamic" -}}
{{-     $dynamic = true -}}
{{-   else if .Values.tenancy.staticTenant -}}
{{-     $tenant = .Values.tenancy.staticTenant -}}
{{-   end -}}
{{- end -}}
{{/* Where the receiver sends traces: one filter per spoke (dynamic), else the single exporter. */}}
{{- $traceInputs := list "otelcol.exporter.otlp.to_tempo.input" -}}
{{- if $dynamic -}}
{{-   $traceInputs = list -}}
{{-   range .Values.spokeClients -}}
{{-     $traceInputs = append $traceInputs (printf "otelcol.processor.filter.traces_%s.input" (include "observability-ingest.alloyId" .name)) -}}
{{-   end -}}
{{- end -}}
logging {
  level  = "info"
  format = "logfmt"
}

/////////////////////////// INGEST (OTLP, mTLS) ///////////////////////////

otelcol.receiver.otlp "ingest" {
  grpc {
    endpoint = "0.0.0.0:{{ .Values.otlp.grpcPort }}"
{{- if .Values.mtls.enabled }}
    tls {
      cert_file      = "/etc/alloy/tls/tls.crt"
      key_file       = "/etc/alloy/tls/tls.key"
      client_ca_file = "/etc/alloy/tls-ca/ca.crt"
    }
{{- end }}
  }
  http {
    endpoint = "0.0.0.0:{{ .Values.otlp.httpPort }}"
{{- if .Values.mtls.enabled }}
    tls {
      cert_file      = "/etc/alloy/tls/tls.crt"
      key_file       = "/etc/alloy/tls/tls.key"
      client_ca_file = "/etc/alloy/tls-ca/ca.crt"
    }
{{- end }}
  }
  output {
    metrics = [otelcol.exporter.prometheus.to_prom.input]
    logs    = [otelcol.exporter.loki.to_loki.input]
    traces  = [{{ join ", " $traceInputs }}]
  }
}

/////////////////////////////// FAN-OUT ///////////////////////////////////

// ---- metrics -> Prometheus remote_write ----
otelcol.exporter.prometheus "to_prom" {
  forward_to = [prometheus.remote_write.prom.receiver]
}
prometheus.remote_write "prom" {
  endpoint {
    url = {{ .Values.backends.prometheus.remoteWriteUrl | quote }}
{{- if $tenant }}
    headers = { "X-Scope-OrgID" = {{ $tenant | quote }} }
{{- end }}
  }
}

// ---- logs -> Loki push ----
{{- if $dynamic }}
// Dynamic per-spoke tenancy. otelcol.exporter.loki promotes the `cluster`
// attribute to a Loki stream label (each spoke sets loki.attribute.labels=cluster),
// so stage.tenant can read it and set X-Scope-OrgID = the originating cluster.
// No per-spoke config; a new spoke is isolated the moment it sends its cluster.
otelcol.exporter.loki "to_loki" {
  forward_to = [loki.process.set_tenant.receiver]
}
loki.process "set_tenant" {
  ///////////////////////// 1. UNWRAP THE OTLP ENVELOPE /////////////////////
  // otelcol.exporter.loki is the deprecated OTLP->Loki shim. When a record
  // carries attributes that were not promoted to stream labels -- which is
  // every record we receive -- it stores the whole record as a JSON envelope:
  //
  //   {"body":"<the application's own log line>",
  //    "attributes":{"namespace":..,"pod":..,"container":..,"node":..},
  //    "resources":{"service.name":..}}
  //
  // So the real line sits one level down, escaped. Grafana shows the envelope,
  // which is why every entry reads as one backslash-riddled blob and why none
  // of the app's fields are filterable. Unwrap it before anything else.
  stage.json {
    expressions = {
      body      = "body",
      namespace = "attributes.namespace",
      container = "attributes.container",
      pod       = "attributes.pod",
      node      = "attributes.node",
    }
  }

  // Low cardinality -> indexed stream labels (these drive Grafana's dropdowns).
  stage.labels {
    values = {
      namespace = "",
      container = "",
    }
  }

  // One value per pod/node -> structured metadata: filterable in Grafana
  // without being indexed, so it cannot explode Loki's stream count.
  stage.structured_metadata {
    values = {
      pod  = "",
      node = "",
    }
  }

  // From here on the line IS the application log line, not the envelope.
  stage.output {
    source = "body"
  }

  ///////////////////////// 2. PARSE THE APPLICATION LINE ///////////////////
  // Guarded on "line starts with {" so plain-text producers (the CNI, Traefik,
  // RabbitMQ, node-exporter) pass through untouched
  // rather than failing a JSON parse on every line.
  //
  // Field names are the application log contract, emitted identically by the
  // .NET and the Python services through their shared logging libraries.
  {{- /* A Helm comment, so the rendered config (and the gateway) does not change:
  the field set below MUST stay identical to observability/templates/_helpers.tpl
  (observability.alloyConfig, alloyPipeline.parseLogContract), which
  parses the same contract on clusters with their own Loki. The LogQL rules in
  observability-log-rules filter on these names on every tenant, and
  tools/compare-log-contract.py fails when the two differ. */}}
  stage.match {
    selector = "{cluster=~\".+\"} |~ \"^\\\\{\""

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
    // particular would otherwise create a stream per URL.
    //
    // NOTE: `exception` is deliberately NOT promoted. Stack traces routinely
    // exceed max_structured_metadata_size (64KB); it stays in the line body.
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

  ///////////////////////// 3. TENANT ROUTING (unchanged) ///////////////////
  stage.tenant {
    label = "cluster"
  }
  forward_to = [loki.write.loki.receiver]
}
loki.write "loki" {
  endpoint {
    url = {{ .Values.backends.loki.pushUrl | quote }}
  }
}
{{- else }}
otelcol.exporter.loki "to_loki" {
  forward_to = [loki.write.loki.receiver]
}
loki.write "loki" {
  endpoint {
    url = {{ .Values.backends.loki.pushUrl | quote }}
{{- if $tenant }}
    tenant_id = {{ $tenant | quote }}
{{- end }}
  }
}
{{- end }}

// ---- traces -> Tempo (OTLP, in-cluster plaintext) ----
{{- if $dynamic }}
// Dynamic per-spoke tenancy for traces. Alloy has no per-attribute trace
// router, so the receiver fans out to one filter per spoke (spokeClients); each
// keeps only the spans stamped with that spoke's `cluster` and exports them with
// X-Scope-OrgID = that cluster. spokeClients is the complete spoke list: a spoke
// not in it has no client cert and cannot connect. A span with no `cluster`
// attribute matches no filter and is dropped.
{{- range .Values.spokeClients }}
{{- $id := include "observability-ingest.alloyId" .name }}
otelcol.processor.filter "traces_{{ $id }}" {
  error_mode = "ignore"
  traces {
    // Conditions DROP what they match: everything that is not this spoke.
    span = [
      `attributes["cluster"] != {{ .name | quote }}`,
    ]
  }
  output {
    traces = [otelcol.exporter.otlp.to_tempo_{{ $id }}.input]
  }
}
otelcol.exporter.otlp "to_tempo_{{ $id }}" {
  client {
    endpoint = {{ $.Values.backends.tempo.otlpEndpoint | quote }}
    headers = { "X-Scope-OrgID" = {{ .name | quote }} }
    tls {
      insecure = true
    }
  }
}
{{- end }}
{{- else }}
otelcol.exporter.otlp "to_tempo" {
  client {
    endpoint = {{ .Values.backends.tempo.otlpEndpoint | quote }}
{{- if $tenant }}
    headers = { "X-Scope-OrgID" = {{ $tenant | quote }} }
{{- end }}
    tls {
      insecure = true
    }
  }
}
{{- end }}
{{- end }}
