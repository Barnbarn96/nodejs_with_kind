kubectl create namespace monitoring || true
helm repo update

# Prometheus/Alertmanager goes through deploy-prometheus.sh, which substitutes
# DISCORD_WEBHOOK_URL_PLACEHOLDER in prometheus-values.yaml with the real
# webhook at deploy time. A plain `helm install -f prometheus-values.yaml`
# here would install the literal placeholder and silently break every Discord
# receiver. (It uses `helm upgrade --install`, so it handles a fresh cluster.)
./monitoring/deploy-prometheus.sh

helm install grafana grafana/grafana -n monitoring -f monitoring/grafana-values.yaml

# helm upgrade prom prometheus-community/prometheus -n monitoring   -f monitoring/prometheus-values.yaml   --set-file serverFiles.alerting_rules\.yml=monitoring/prometheus-rules.yaml