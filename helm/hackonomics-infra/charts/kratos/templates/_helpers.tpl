{{- define "kratos.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kratos.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "kratos" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "kratos.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "kratos.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "kratos.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kratos.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
