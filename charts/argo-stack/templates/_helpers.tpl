{{/*
Expand the name of the chart.
*/}}
{{- define "argo-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified app name.
*/}}
{{- define "argo-stack.fullname" -}}
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
Common labels
*/}}
{{- define "argo-stack.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "argo-stack.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: argo-stack
{{- end }}

{{/*
Selector labels
*/}}
{{- define "argo-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "argo-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "argo-stack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "argo-stack.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
PostgreSQL Cluster name
*/}}
{{- define "argo-stack.pgClusterName" -}}
{{- printf "%s-%s" (include "argo-stack.fullname" .) .Values.postgresql.clusterName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
PostgreSQL primary read-write service name (CNPG convention: <cluster>-rw)
*/}}
{{- define "argo-stack.pgRwService" -}}
{{- printf "%s-rw" (include "argo-stack.pgClusterName" .) }}
{{- end }}

{{/*
Ollama service name
*/}}
{{- define "argo-stack.ollamaService" -}}
{{- printf "%s-ollama" (include "argo-stack.fullname" .) }}
{{- end }}

{{/*
Langflow service name
*/}}
{{- define "argo-stack.langflowService" -}}
{{- printf "%s-langflow" (include "argo-stack.fullname" .) }}
{{- end }}
