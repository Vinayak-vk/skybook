{{/*
Labels on every object the chart renders.
*/}}
{{- define "skybook.labels" -}}
app.kubernetes.io/part-of: skybook
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
skybook.io/environment: {{ .Values.environment }}
{{- end }}

{{/*
Selector label for one service. Expects a dict with "name". Kept separate from
the common labels above (and disjoint from them) so it can be combined with
them without duplicate keys.
*/}}
{{- define "skybook.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
{{- end }}

{{/*
The workload kind: an Argo Rollout when canaries are on, else a Deployment.
*/}}
{{- define "skybook.workloadApiVersion" -}}
{{- if .Values.rollout.enabled }}argoproj.io/v1alpha1{{ else }}apps/v1{{ end }}
{{- end }}

{{- define "skybook.workloadKind" -}}
{{- if .Values.rollout.enabled }}Rollout{{ else }}Deployment{{ end }}
{{- end }}

{{/*
Pod template shared by Deployments and Rollouts.
Expects a dict with "root" (the top-level context), "name" and "svc".
*/}}
{{- define "skybook.podTemplate" -}}
{{- $root := .root -}}
{{- $svc := .svc -}}
metadata:
  labels:
    {{- include "skybook.labels" $root | nindent 4 }}
    {{- include "skybook.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/version: {{ $svc.tag | quote }}
spec:
  {{- with $root.Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 30
  securityContext:
    runAsNonRoot: true
    runAsUser: {{ $svc.runAsUser }}
    runAsGroup: {{ $svc.runAsUser }}
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: {{ .name }}
      image: "{{ $root.Values.image.registry }}/{{ $svc.image }}:{{ required (printf "services.%s.tag must be set" .name) $svc.tag }}"
      imagePullPolicy: {{ $root.Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ $svc.port }}
          protocol: TCP
      env:
        - name: APP_ENV
          value: {{ $root.Values.environment | quote }}
        {{- range $key, $value := $svc.env }}
        - name: {{ $key }}
          value: {{ $value | quote }}
        {{- end }}
        {{- if $svc.database }}
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: {{ $root.Values.database.name }}-app
              key: uri
        {{- end }}
      # booking-api waits up to a minute for Postgres on boot; the startup probe
      # keeps the liveness probe from killing it in the meantime.
      startupProbe:
        httpGet:
          path: {{ $svc.livenessPath }}
          port: http
        periodSeconds: 2
        failureThreshold: 45
      livenessProbe:
        httpGet:
          path: {{ $svc.livenessPath }}
          port: http
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
      readinessProbe:
        httpGet:
          path: {{ $svc.readinessPath }}
          port: http
        periodSeconds: 5
        timeoutSeconds: 2
        failureThreshold: 3
      resources:
        {{- toYaml $svc.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        {{- range $i, $path := $svc.writablePaths }}
        - name: writable-{{ $i }}
          mountPath: {{ $path }}
        {{- end }}
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
    {{- range $i, $path := $svc.writablePaths }}
    - name: writable-{{ $i }}
      emptyDir:
        sizeLimit: 8Mi
    {{- end }}
{{- end }}
