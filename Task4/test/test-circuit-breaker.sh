#!/usr/bin/env bash
# Проверка circuit breaker: nginx с nginx-circuit-breaker.conf + мок логистики в отдельной docker-сети.
# Мок доступен под именем logistics.company.com, поэтому конфиг проверяется без изменений
set -u

cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

NET=nova-cb-test
# На Windows (Git Bash) docker нужен путь вида D:/..., его даёт pwd -W; на Linux и macOS — обычный pwd
DIR="$(pwd -W 2>/dev/null || pwd)"
docker rm -f cb-nginx cb-logistics cb-client >/dev/null 2>&1
docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null

docker run -d --name cb-logistics --network "$NET" --network-alias logistics.company.com \
  -v "$DIR/logistics_mock.py:/app/mock.py:ro" python:3.12-alpine python -u /app/mock.py >/dev/null
sleep 2
docker run -d --name cb-nginx --network "$NET" \
  -v "$DIR/../nginx-circuit-breaker.conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine >/dev/null
docker run -d --name cb-client --network "$NET" curlimages/curl:8.11.1 sleep infinity >/dev/null
sleep 2

docker exec cb-nginx nginx -t 2>&1

mode() {
  docker exec cb-client curl -s "http://logistics.company.com:9000/mode/$1"
  echo "--- логистика переключена в режим: $1"
}

call() {
  local label="$1"
  docker exec cb-client curl -s -o /tmp/body -w "%{http_code} %{time_total}s" http://cb-nginx:8080/logistics/track/NM-0001 \
    | { read -r code elapsed; printf '%-44s HTTP %s за %-10s %s\n' "$label" "$code" "$elapsed" "$(docker exec cb-client cat /tmp/body)"; }
}

echo
echo "=== 1. Логистика работает — запрос проходит ==="
mode ok
call "нормальный запрос"

echo
echo "=== 2. Логистика тормозит 5 с — таймаут 3 с и fallback, после 5 неудач breaker открывается ==="
mode slow
for i in 1 2 3 4 5; do call "медленный ответ, попытка $i"; done
call "6-й запрос: breaker открыт"
call "7-й запрос: breaker открыт"

echo
echo "=== 3. Логистика восстановилась, но 30 с ещё не прошли — запросы к ней не идут ==="
mode ok
call "сразу после восстановления"

echo
echo "=== 4. Через 30 с breaker пропускает пробный запрос, вызовы восстанавливаются ==="
sleep 31
call "через 31 с"
call "следующий запрос"

echo
echo "=== 5. Логистика отвечает 500 — 5 ошибок подряд открывают breaker ==="
mode error
for i in 1 2 3 4 5; do call "ошибка 500, попытка $i"; done
call "6-й запрос: breaker открыт"

echo
echo "=== 6. Пробный запрос через 30 с снова неудачный — breaker закрывается ещё на 30 с ==="
sleep 31
call "через 31 с, логистика всё ещё 500"
mode ok
call "логистика починилась, 30 с не прошли"
sleep 31
call "ещё через 31 с"

echo
echo "=== Какие запросы реально дошли до логистики ==="
docker logs cb-logistics 2>&1

docker rm -f cb-nginx cb-logistics cb-client >/dev/null
docker network rm "$NET" >/dev/null
