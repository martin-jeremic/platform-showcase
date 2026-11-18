{{- define "product-a-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "product-a-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "product-a-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "product-a-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "product-a-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "product-a-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: product-a
{{- end }}

{{- define "product-a-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "product-a-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- /*
Digest-only image reference. There is deliberately no tag fallback: a tag is mutable, so a
render that "works" with a tag deploys whatever the tag points at on the day a node pulls it.
The GitOps promotion writes image.digest per environment; anything else fails the render here,
in CI or in Argo's ComparisonError, before a pod exists. That is also why pullPolicy is
IfNotPresent: a digest cannot change under the same reference, so Always only adds a registry
round-trip (and a registry outage) to every pod start.
*/ -}}
{{- define "product-a-api.image" -}}
{{- $digest := required "image.digest is required (sha256:<64 hex>): this chart deploys by digest only" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex>, got %q" $digest) -}}
{{- end -}}
{{- printf "%s@%s" (required "image.repository is required" .Values.image.repository) $digest -}}
{{- end }}

{{- /*
One HTTPRoute rule. Params: root, path, rewrite (falls back to route.rewrite when empty).
Called once per explicit rule in httproute.yaml.
*/ -}}
{{- define "product-a-api.routeRule" -}}
{{- $rewrite := default .root.Values.route.rewrite .rewrite -}}
- matches:
    - path:
        type: PathPrefix
        value: {{ required "route path is required" .path | quote }}
  {{- if $rewrite.enabled }}
  filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: {{ $rewrite.replacePrefixMatch | quote }}
  {{- end }}
  backendRefs:
    - group: ""
      kind: Service
      name: {{ include "product-a-api.fullname" .root }}
      port: {{ .root.Values.service.port }}
      weight: 1
{{- end }}
