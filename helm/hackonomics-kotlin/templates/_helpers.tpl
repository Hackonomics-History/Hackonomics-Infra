{{- define "hackonomics-kotlin.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hackonomics-kotlin.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "backend-kotlin" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "hackonomics-kotlin.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "hackonomics-kotlin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "hackonomics-kotlin.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hackonomics-kotlin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
