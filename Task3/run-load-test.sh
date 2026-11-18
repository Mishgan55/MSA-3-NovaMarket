#!/usr/bin/env bash
# Полный прогон проверки HPA: пишет состояние кластера, даёт нагрузку locust, затем ждёт обратного масштабирования.
# Locust запускается в контейнере в docker-сети minikube и ходит на NodePort сервиса: запросы проходят через Service
# и распределяются по всем подам (kubectl port-forward привязался бы к одному поду)
set -u

cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

NAMESPACE="${NAMESPACE:-novamarket}"
USERS="${USERS:-500}"
LOAD_TIME="${LOAD_TIME:-7m}"
SPAWN_RATE="${SPAWN_RATE:-20}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-480}"
RESULTS="${RESULTS:-results}"
# На Windows (Git Bash) docker нужен путь вида D:/..., его даёт pwd -W; на Linux и macOS — обычный pwd
DIR="$(pwd -W 2>/dev/null || pwd)"
HOST="http://$(minikube ip):30080"

mkdir -p "$RESULTS"

bash watch-scaling.sh 100000 > "$RESULTS/scaling.log" 2>&1 &
WATCHER=$!

echo "$(date '+%H:%M:%S') старт нагрузки: $USERS пользователей (+$SPAWN_RATE в секунду), $LOAD_TIME, $HOST"
docker run --rm --name locust --network minikube -v "$DIR:/mnt/locust" -w /mnt/locust locustio/locust:2.32.4 \
  -f locustfile.py --headless --host "$HOST" --users "$USERS" --spawn-rate "$SPAWN_RATE" --run-time "$LOAD_TIME" \
  --csv "$RESULTS/locust" --only-summary > "$RESULTS/locust.log" 2>&1
echo "$(date '+%H:%M:%S') нагрузка снята, ждём обратного масштабирования $COOLDOWN_SECONDS с"

sleep "$COOLDOWN_SECONDS"
kill "$WATCHER"

kubectl -n "$NAMESPACE" describe hpa scaletestapp > "$RESULTS/hpa-describe.txt"
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp \
  --field-selector involvedObject.name=scaletestapp > "$RESULTS/hpa-events.txt"
echo "$(date '+%H:%M:%S') готово"
