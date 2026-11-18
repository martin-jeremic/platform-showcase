{{- define "elasticsearch.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "elasticsearch.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "elasticsearch.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "elasticsearch.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name. Honors an explicit override, else the release fullname.
*/}}
{{- define "elasticsearch.serviceAccountName" -}}
{{- if .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
{{- include "elasticsearch.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Where the `elastic` superuser password comes from: the CSI-synced Secret (Key
Vault), or a pre-created Secret. Never from values.
*/}}
{{- define "elasticsearch.secretName" -}}
{{- if .Values.azureKeyVault.enabled -}}
{{- .Values.azureKeyVault.syncedSecretName -}}
{{- else -}}
{{- required "auth.existingSecret is required when security is on and azureKeyVault.enabled is false" .Values.auth.existingSecret -}}
{{- end -}}
{{- end -}}

{{- define "elasticsearch.passwordKey" -}}
{{- if .Values.azureKeyVault.enabled -}}elasticsearchPassword{{- else -}}{{ .Values.auth.existingSecretKey }}{{- end -}}
{{- end -}}

{{/*
Input validation, included by the StatefulSet.

security.enabled=false is refused unless the operator ALSO sets
security.allowInsecure: an unauthenticated Elasticsearch gives anything that can
reach :9200 full read/write on every index. The forked chart hardcoded
xpack.security.enabled=false and published the service through an HTTPRoute on a
host that was not even a SAN on the gateway certificate -- the one protection it
had was a browser certificate warning.
*/}}
{{- define "elasticsearch.validate" -}}
{{- if and (not .Values.security.enabled) (not .Values.security.allowInsecure) -}}
{{- fail "security.enabled=false renders an unauthenticated Elasticsearch. Set security.allowInsecure=true as well if that is really intended (local throwaway clusters only)" -}}
{{- end -}}
{{- if not .Values.persistence.storageClass -}}
{{- fail "persistence.storageClass is required -- set it to platform-retain, never leave it empty (empty = the cluster default class, reclaimPolicy Delete)" -}}
{{- end -}}
{{- end -}}
