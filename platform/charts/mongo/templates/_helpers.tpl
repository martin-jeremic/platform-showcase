{{/*
Expand the name of the chart.
*/}}
{{- define "mongo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mongo.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mongo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mongo.labels" -}}
helm.sh/chart: {{ include "mongo.chart" . }}
{{ include "mongo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mongo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the Secret holding credentials: the CSI-synced Secret (Key Vault), or a
pre-created Secret (auth.existingSecret). The chart renders no password Secret of
its own -- a template that can turn `auth.password` from values into a Secret
eventually turns a committed password into one.
*/}}
{{- define "mongo.secretName" -}}
{{- if .Values.azureKeyVault.enabled }}
{{- .Values.azureKeyVault.syncedSecretName }}
{{- else }}
{{- required "auth.existingSecret is required when azureKeyVault.enabled is false (keys mongo-username, mongo-password)" .Values.auth.existingSecret }}
{{- end }}
{{- end }}

{{/*
Key inside the credential Secret that holds the admin password.

Two different key names by design, because the two sources are shaped differently:
  - CSI path: the key is whatever azureKeyVault.secrets[].key says. It is looked up by
    matching on env == MONGO_INITDB_ROOT_PASSWORD rather than hardcoded, so the overlay
    stays the single source of truth for the vault->secret->env mapping.
  - existingSecret path: the key is fixed (mongo-password).
Fails loudly if the CSI list has no MONGO_INITDB_ROOT_PASSWORD entry — a silently empty
key name renders a StatefulSet whose pod never starts, with no clue why.
*/}}
{{- define "mongo.passwordKey" -}}
{{- if .Values.azureKeyVault.enabled -}}
{{- $key := "" -}}
{{- range .Values.azureKeyVault.secrets -}}
{{- if eq .env "MONGO_INITDB_ROOT_PASSWORD" }}{{ $key = .key }}{{ end -}}
{{- end -}}
{{- if not $key }}{{ fail "azureKeyVault.enabled=true but azureKeyVault.secrets has no entry with env: MONGO_INITDB_ROOT_PASSWORD — the admin password must be one of the synced secrets" }}{{ end -}}
{{- $key -}}
{{- else -}}
mongo-password
{{- end -}}
{{- end }}

{{/*
ServiceAccount the backup CronJob runs as.

Dedicated on purpose. This is the identity a federated credential binds to, and binding one
to the namespace `default` SA would let every pod in the namespace — mongod included —
assume the storage identity. The full subject for the Azure federated credential is:
  system:serviceaccount:<release namespace>:<this name>
*/}}
{{- define "mongo.backupServiceAccountName" -}}
{{- if .Values.backup.serviceAccount.name -}}
{{- .Values.backup.serviceAccount.name -}}
{{- else -}}
{{- printf "%s-backup" (include "mongo.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Image used by the backup CronJob's mongodump step.
Defaults to the mongod image so the CronJob adds no extra pull on the node.
*/}}
{{- define "mongo.backupImage" -}}
{{- $repo := .Values.backup.image.repository | default .Values.image.repository -}}
{{- $tag := .Values.backup.image.tag | default .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end }}

{{/*
Key inside the credential Secret holding the Azure Storage connection string.
Looked up by env name, the same way passwordKey is, so azureKeyVault.secrets stays the
single source of truth. Only used when backup.azure.authMode == connectionString.
*/}}
{{- define "mongo.blobConnectionStringKey" -}}
{{- $key := "" -}}
{{- range .Values.azureKeyVault.secrets -}}
{{- if eq .env "AZURE_STORAGE_CONNECTION_STRING" }}{{ $key = .key }}{{ end -}}
{{- end -}}
{{- if not $key }}{{ fail "backup.azure.authMode=connectionString requires an azureKeyVault.secrets entry with env: AZURE_STORAGE_CONNECTION_STRING (or use workloadIdentity)" }}{{ end -}}
{{- $key -}}
{{- end }}

{{/*
Name of the PVC.
*/}}
{{- define "mongo.pvcName" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- include "mongo.fullname" . }}
{{- end }}
{{- end }}

{{/*
ServiceAccount mongod itself runs as -- the one federated for Key Vault access
when azureKeyVault.authMode is workloadIdentity. Separate from the backup SA:
the backup identity may write to the storage account, mongod's may not.
*/}}
{{- define "mongo.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default (include "mongo.fullname" .) -}}
{{- end }}
