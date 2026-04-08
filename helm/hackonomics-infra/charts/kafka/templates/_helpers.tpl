{{- define "kafka.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kafka.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name "kafka" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "kafka.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "kafka.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Headless service name — used by the StatefulSet and KRaft quorum voter config.
*/}}
{{- define "kafka.headlessName" -}}
{{- printf "%s-headless" (include "kafka.fullname" .) }}
{{- end }}

{{/*
Stable DNS name of pod-0 — used as the KRaft controller quorum voter address.
Format: <pod-0>.<headless-svc>.<namespace>.svc.cluster.local
*/}}
{{- define "kafka.pod0DNS" -}}
{{- printf "%s-0.%s.%s.svc.cluster.local"
    (include "kafka.fullname" .)
    (include "kafka.headlessName" .)
    .Release.Namespace }}
{{- end }}
