{{- define "postgres-django.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "postgres-django.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "postgres-django" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "postgres-django.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "postgres-django.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "postgres-django.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgres-django.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
