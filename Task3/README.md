# Задание 3. Масштабирование под нагрузку (HPA по памяти)

| Файл | Что это |
| :- | :- |
| [deployment.yaml](deployment.yaml) | Deployment тестового приложения `ghcr.io/yandex-practicum/scaletestapp:latest`: 1 реплика, лимит памяти 30Mi |
| [service.yaml](service.yaml) | Service для доступа к приложению (NodePort 30080 → порт 8080) |
| [hpa.yaml](hpa.yaml) | HorizontalPodAutoscaler: память, цель 80%, от 1 до 10 реплик |
| [locustfile.py](locustfile.py) | Сценарий нагрузки из задания |
| [run-load-test.sh](run-load-test.sh), [watch-scaling.sh](watch-scaling.sh) | Прогон нагрузки и запись состояния HPA каждые 15 с |
| [results/](results) | Логи прогона — доказательство изменения числа реплик |

## Как развёрнуто

```bash
minikube start
minikube addons enable metrics-server

kubectl create namespace novamarket
kubectl -n novamarket apply -f deployment.yaml -f service.yaml -f hpa.yaml
kubectl -n novamarket get hpa
```

Приложение развёрнуто в отдельном namespace `novamarket`. В `default` на этом кластере после прошлого спринта включена автоинъекция Istio sidecar. Sidecar добавил бы в под свой контейнер с собственными requests памяти и исказил бы утилизацию, по которой работает HPA.

## Решения в манифестах

**Deployment.**
- **Лимит памяти — 30Mi**, как требует задание.
- **`requests.memory: 20Mi` задан явно.** HPA считает утилизацию памяти от `requests`, а не от `limits`: без `requests` HPA по памяти вообще не работает.
- **Почему `requests` 20Mi, а не 30Mi.** Это проверено на первом прогоне: при `requests = limits = 30Mi` под нагрузкой память держалась на 71–75%. HPA не масштабирует, пока отклонение от цели меньше 10% (`--horizontal-pod-autoscaler-tolerance`), то есть реплика добавилась бы только при ~88% = 26,4Mi — вплотную к лимиту, когда под уже рискует получить OOMKilled. Это ровно проблема из условия: «перезагрузки из-за нехватки памяти». При `requests` 20Mi цель 80% = 16Mi, и реплики добавляются, когда до лимита ещё есть запас.
- **Пробы.** Readiness и liveness проверяют `/metrics`: новый под получает трафик только когда готов.

**Service** — `NodePort`, чтобы нагрузку можно было подать снаружи кластера через балансировку Service по всем подам.

**HPA** (`autoscaling/v2`):
- `minReplicas: 1`, `maxReplicas: 10`, метрика `memory`, `averageUtilization: 80`;
- `behavior.scaleUp` — без окна стабилизации, можно удваивать число подов каждые 15 с: под нагрузкой реагируем сразу;
- `behavior.scaleDown` — окно стабилизации 120 с и не больше одного пода за 30 с: после пика не сносим поды при первом же снижении.

## Нагрузка

Locust запускается с [locustfile.py](locustfile.py) из задания (пауза между запросами 1–5 с).

Прогон автоматизирован в [run-load-test.sh](run-load-test.sh):
1. Включает запись состояния HPA, deployment и `kubectl top` каждые 15 с.
2. Даёт нагрузку 500 пользователей в течение 7 минут.
3. После снятия нагрузки ещё 8 минут наблюдает за обратным масштабированием.

**Где запускается locust.** Locust работает в контейнере `locustio/locust` внутри docker-сети `minikube` и ходит на `http://<minikube ip>:30080`, то есть через Service на все поды. `kubectl port-forward svc/...` для этого не годится: он привязывается к одному поду, и новые реплики не получали бы нагрузку.

Тот же сценарий можно запустить с веб-интерфейсом, как в задании (`locust`, затем http://localhost:8089, Host — URL из `minikube service scaletestapp -n novamarket --url`), и смотреть на поды в `minikube dashboard`.

## Результат

Сделано три прогона, логи каждого лежат в своей папке:
- `scaling.log` — HPA, deployment и `kubectl top` каждые 15 с;
- `hpa-events.txt` и `hpa-describe.txt` — события масштабирования;
- `locust.log` и `locust_*.csv` — статистика нагрузки.

| Прогон | Нагрузка | Реплики | Запросов / ошибок | Логи |
| :- | :- | :- | :- | :- |
| 1 | 500 пользователей, +20 в секунду, 7 мин | **1 → 2** | 68 044 / 0 | [run1-500-users](results/run1-500-users) |
| 2 | 1500 пользователей, +20 в секунду, 6 мин | 1, под 6 раз убит по OOM | 26 648 / 14,6% | [run2-1500-users](results/run2-1500-users) |
| 3 | 1500 пользователей, +2 в секунду, 15 мин | **1 → 2 → 3 → 4 → 5 → 6** | 262 265 / 0,01% | [run3-1500-users-ramp](results/run3-1500-users-ramp) |

### Прогон 3 — масштабирование по шагам

События HPA ([hpa-events.txt](results/run3-1500-users-ramp/hpa-events.txt)):

```
SuccessfulRescale   New size: 2; reason: memory resource utilization (percentage of request) above target
SuccessfulRescale   New size: 3; reason: memory resource utilization (percentage of request) above target
SuccessfulRescale   New size: 4; reason: memory resource utilization (percentage of request) above target
SuccessfulRescale   New size: 5; reason: memory resource utilization (percentage of request) above target
SuccessfulRescale   New size: 6; reason: memory resource utilization (percentage of request) above target
```

| Время | Пользователей (≈) | Утилизация памяти (от requests) | Реплик |
| :-: | :-: | :-: | :-: |
| 11:54 | 0 | 36% | 1 |
| 11:57:54 | 470 | 101% | 2 |
| 12:00:02 | 720 | 88% | 3 |
| 12:03:57 | 1200 | 98% | 4 |
| 12:06:59 | 1500 | 95% | 5 |
| 12:08:04 | 1500 | 90% | 6 |
| 12:12:48 (нагрузка снята) | 0 | 80% | 6 |

Память по подам на пике ([scaling.log](results/run3-1500-users-ramp/scaling.log), 12:08:53):

```
NAME                           CPU(cores)   MEMORY(bytes)
scaletestapp-fb65fd59f-7l47h   51m          23Mi
scaletestapp-fb65fd59f-l7vxn   18m          13Mi
scaletestapp-fb65fd59f-nldjf   35m          19Mi
scaletestapp-fb65fd59f-rvgn7   66m          28Mi
scaletestapp-fb65fd59f-tjwvr   2m           9Mi
scaletestapp-fb65fd59f-w9w5h   1m           8Mi
```

Locust: 262 265 запросов, 291 r/s, медиана 2 мс, p99 38 мс. 15 ошибок соединения пришлись на единственный рестарт пода по OOM в 12:05, когда реплик было 4.

### Выводы

1. **HPA по памяти работает: число реплик растёт вслед за нагрузкой.** Масштабирование вверх прошло пятью шагами за 10 минут, приложение отвечало без деградации.
2. **Резкий скачок HPA по памяти не ловит (прогон 2).** При наплыве 20 новых пользователей в секунду память единственного пода выросла с 7Mi до лимита 30Mi быстрее, чем metrics-server снял метрику (окно ~15–60 с). Под получил `OOMKilled` (exit code 137) и ушёл в рестарты. Пока под перезапускается, метрики нет (`<unknown>`), и HPA не может посчитать нужное число реплик. Ровно та картина, что описана в задании: «постоянно перезагружая поды из-за нехватки памяти». Что с этим делать:
   - `minReplicas` выставлять по ожидаемому базовому пику, а не 1;
   - добавить в HPA метрику, которая растёт раньше памяти: RPS по `http_requests_total` через Prometheus Adapter или KEDA, либо CPU. HPA берёт максимум из рекомендаций по всем метрикам;
   - для известных пиков (распродажи) — плановое масштабирование заранее.
3. **Обратного масштабирования не произошло.** После снятия нагрузки память подов не освобождается: 22–23Mi у нагруженных подов спустя 4 минуты, утилизация держится на 80%. HPA по памяти поэтому не уменьшает число реплик. Для приложений, которые не возвращают память (JVM, Go с ленивым GC, кэши), HPA только по памяти — однонаправленный: для scale-down нужна метрика нагрузки (RPS или CPU), которая падает вместе с трафиком.
4. **Нагрузка между подами неравномерна.** Новые поды получают мало запросов: 8–9Mi против 23–28Mi у старых. Service (kube-proxy) балансирует TCP-соединения, а не запросы, а locust держит keep-alive соединения, открытые до появления новых подов. Поэтому старые поды продолжают расти и упираются в лимит (тот самый OOM в 12:05), хотя средняя утилизация терпима. В бою это решается L7-балансировкой (NGINX Ingress, Istio) или ограничением времени жизни keep-alive соединений.
