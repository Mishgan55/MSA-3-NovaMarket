#!/usr/bin/env bash
# Каждые 15 секунд пишет состояние HPA, подов и их потребление памяти — так видно, как меняется число реплик под нагрузкой
# Использование: ./watch-scaling.sh [длительность в секундах] > scaling.log
set -u

NAMESPACE="${NAMESPACE:-novamarket}"
DURATION="${1:-900}"
INTERVAL=15

end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
  kubectl -n "$NAMESPACE" get hpa scaletestapp
  kubectl -n "$NAMESPACE" get deploy scaletestapp
  kubectl -n "$NAMESPACE" top pod -l app=scaletestapp 2>/dev/null
  echo
  sleep "$INTERVAL"
done
