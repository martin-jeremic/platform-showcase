{{- /*
Shared helpers for the three payments .NET backend charts (payments-api, payments-invoicing,
payments-email). The define namespace is deliberately NEUTRAL ("payments-backend.*", not
"payments-api.*") so the three charts carry a byte-identical templates/ directory: a fix is
copied, not re-applied by hand three times with three chances to diverge. They are packaged and
rendered as separate top-level charts, so the identical define names never collide. Per-chart
identity comes from Chart.yaml (.Chart.Name) and the values.

Only payments-api is shown in the showcase; see the payments README.
*/ -}}

{{- define "payments-backend.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "payments-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "payments-backend.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "payments-backend.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: payments
{{- end }}

{{- define "payments-backend.image" -}}
{{- $digest := required "image.digest is required (sha256:<64 hex>)" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex>, got %q" $digest) -}}
{{- end -}}
{{- printf "%s@%s" (required "image.repository is required" .Values.image.repository) $digest -}}
{{- end }}

{{- define "payments-backend.secretName" -}}
{{- if .Values.azureKeyVault.enabled }}{{ .Values.azureKeyVault.syncedSecretName }}{{ else }}{{ .Values.fallbackSecret.name }}{{ end }}
{{- end }}
