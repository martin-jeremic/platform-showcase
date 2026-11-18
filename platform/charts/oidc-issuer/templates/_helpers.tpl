{{/*
Base name for resources rendered by this chart.
*/}}
{{- define "oidc-issuer.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels stamped on every object this chart owns.
*/}}
{{- define "oidc-issuer.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
The backend is Service `kubernetes`, which only exists in namespace `default`.
The HTTPRoute and BackendTLSPolicy must sit in the same namespace as that
Service: a cross-namespace backendRef without a ReferenceGrant is accepted by
the API server and simply never resolves, so the issuer would 404 while Argo
reports Healthy. Fail the render instead.
*/}}
{{- define "oidc-issuer.assertNamespace" -}}
{{- if ne .Release.Namespace "default" -}}
{{- fail (printf "oidc-issuer must be installed into namespace default (next to Service kubernetes); got %q" .Release.Namespace) -}}
{{- end -}}
{{- end -}}
