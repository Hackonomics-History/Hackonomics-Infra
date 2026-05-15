{{- define "hackonomics-fastapi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hackonomics-fastapi.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "backend-fastapi" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "hackonomics-fastapi.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "hackonomics-fastapi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "hackonomics-fastapi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hackonomics-fastapi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
