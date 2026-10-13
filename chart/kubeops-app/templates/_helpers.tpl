{{- define "kubeops-app.labels" -}}
app.kubernetes.io/name: {{ required "app is required (--set app=...)" .Values.app }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
kubeops/app: {{ .Values.app | quote }}
{{- end }}
