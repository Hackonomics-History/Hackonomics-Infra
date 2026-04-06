{{- define "redis-go.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "redis-go.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "redis-go" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "redis-go.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "redis-go.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "redis-go.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-go.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
