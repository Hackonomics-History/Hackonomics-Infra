{{- define "redis-django.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "redis-django.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "redis-django" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "redis-django.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "redis-django.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "redis-django.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-django.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
