{{/* Common labels */}}
{{- define "grafana-sso-gateway.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* OIDC issuer URL (realm base), trimming any trailing slash on baseUrl */}}
{{- define "grafana-sso-gateway.issuer" -}}
{{- printf "%s/realms/%s" (trimSuffix "/" (required "oidc.keycloak.baseUrl is required when oidc.enabled" .Values.oidc.keycloak.baseUrl)) .Values.oidc.keycloak.realm -}}
{{- end -}}
