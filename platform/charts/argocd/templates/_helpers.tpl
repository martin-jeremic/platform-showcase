{{/*
Name of the Argo CD server Service, derived from the argo-cd subchart's
fullnameOverride so the HTTPRoute always targets the right backend regardless of
the Helm release name.
*/}}
{{- define "platform-argocd.serverServiceName" -}}
{{- $override := index .Values "argo-cd" "fullnameOverride" | default "" -}}
{{- if $override -}}
  {{- printf "%s-server" $override -}}
{{- else -}}
  {{- printf "%s-argo-cd-server" .Release.Name -}}
{{- end -}}
{{- end }}

{{/*
Common labels applied to wrapper-chart resources (the HTTPRoute).
*/}}
{{- define "platform-argocd.labels" -}}
app.kubernetes.io/name: argocd
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
