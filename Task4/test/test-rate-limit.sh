#!/usr/bin/env bash
# Проверка rate limiter: nginx с nginx-rate-limit.conf перед заглушкой бэкенда.
# Нагрузка подаётся с одного IP 10 секунд с постоянной частотой 100 запросов в секунду — выше обоих лимитов.
# Ожидание: веб пропускается ~50 r/s, мобилка и клиент без заголовка — ~30 r/s, остальное получает 429
set -u

cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

NET=nova-rl-test
# На Windows (Git Bash) docker нужен путь вида D:/..., его даёт pwd -W; на Linux и macOS — обычный pwd
DIR="$(pwd -W 2>/dev/null || pwd)"
DURATION=10
RATE=100

docker rm -f rl-nginx rl-backend >/dev/null 2>&1
docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null

# Бэкенд — стандартный nginx, отвечающий 200 на любой путь
docker run -d --name rl-backend --network "$NET" --network-alias backend nginx:1.27-alpine \
  sh -c 'printf "server { listen 80; location / { return 200 ok; } }" > /etc/nginx/conf.d/default.conf && nginx -g "daemon off;"' >/dev/null
docker run -d --name rl-nginx --network "$NET" \
  -v "$DIR/../nginx-rate-limit.conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine >/dev/null
sleep 2

docker exec rl-nginx nginx -t 2>&1

load() {
  local label="$1" header="$2" expected="$3"
  echo
  echo "=== $label: $RATE r/s в течение $DURATION с, ожидаемый лимит $expected r/s ==="
  docker run --rm -i --network "$NET" grafana/k6:0.55.0 run --quiet - <<EOF 2>&1 | grep -E "status_|http_reqs"
import http from 'k6/http';
import { Counter } from 'k6/metrics';
const ok = new Counter('status_200');
const limited = new Counter('status_429');
export const options = {
  scenarios: { constant: { executor: 'constant-arrival-rate', rate: $RATE, timeUnit: '1s', duration: '${DURATION}s', preAllocatedVUs: 50 } },
  summaryTrendStats: ['avg'],
};
export default function () {
  const res = http.get('http://rl-nginx/api/catalog', { headers: { $header } });
  if (res.status === 200) ok.add(1);
  if (res.status === 429) limited.add(1);
}
EOF
  # Новый запуск начинается с пустого счётчика: ждём, пока окно лимита очистится
  sleep 2
}

load "Веб-приложение (X-Client-Type: web)" "'X-Client-Type': 'web'" 50
load "Мобильное приложение (X-Client-Type: mobile)" "'X-Client-Type': 'mobile'" 30
load "Клиент без заголовка канала" "" 30

docker rm -f rl-nginx rl-backend >/dev/null
docker network rm "$NET" >/dev/null
