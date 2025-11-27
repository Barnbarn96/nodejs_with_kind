kubectl create namespace monitoring || true
helm repo update
helm install prom prometheus-community/prometheus -n monitoring -f monitoring/prometheus-values.yaml
helm install grafana grafana/grafana -n monitoring -f monitoring/grafana-values.yaml

# helm upgrade prom prometheus-community/prometheus -n monitoring   -f monitoring/prometheus-values.yaml   --set-file serverFiles.alerting_rules\.yml=monitoring/prometheus-rules.yaml