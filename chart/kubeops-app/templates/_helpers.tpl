{{- define "kubeops-app.labels" -}}
app.kubernetes.io/name: {{ required "app es obligatorio (--set app=...)" .Values.app }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
kubeops/app: {{ .Values.app | quote }}
{{- end }}
