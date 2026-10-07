## Практика: приложение в виртуальной машине и managed PostgreSQL

Небольшое практическое задание для Cozystack. Вы разворачиваете управляемую базу данных PostgreSQL и виртуальную машину с простым веб-приложением на Python, которое пишет и читает записи в этой базе. Цель: увидеть, как код, живущий в виртуальной машине, использует базу данных из того же тенанта по внутреннему сетевому имени сервиса.

## Что вы построите

```
 namespace вашего тенанта (tenant-<вы>)
 +------------------------------------------+
 |  VMInstance "app"                        |
 |    Ubuntu 24.04 + Flask на порту 8080    |
 |    приложение читает и пишет записи      |
 +---------------------+--------------------+
                       |
                       |  TCP 5432, протокол libpq
                       v
 +------------------------------------------+
 |  Postgres "demo" (managed, CloudNativePG)|
 |    сервис: postgres-demo-rw              |
 |    база: appdb, пользователь: appuser    |
 +------------------------------------------+
```

Приложение подключается к базе по внутреннему DNS-имени сервиса `postgres-demo-rw.<namespace>.svc` и по стандартным переменным libpq (`PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`). Пароль базы берётся из секрета, который создаёт сам managed-Postgres, и попадает в машину через cloud-init. В git пароль не хранится.

## Быстрый вариант: один файл из дашборда (без терминала)

Если нужно создать всё из дашборда Cozystack, используйте готовый файл `manifests/all-in-one-dashboard.yaml`. Это один манифест с тремя ресурсами (Postgres, диск машины и сама машина), который создаёт всё сразу. Терминал не нужен, вход в машину по логину и паролю. Код приложения машина подтягивает сама: cloud-init клонирует этот репозиторий.

Порядок действий:

1. Откройте дашборд и войдите в свой тенант.
2. Создайте ресурс из YAML и вставьте содержимое `manifests/all-in-one-dashboard.yaml`. Если редактор дашборда создаёт по одному ресурсу за раз, вставьте три документа по очереди (они разделены строкой `---`): сначала Postgres, затем VMDisk, затем VMInstance.
3. Дождитесь, пока Postgres станет Ready, а машина перейдёт в Running и отработает cloud-init (установка пакетов занимает около минуты).
4. Войдите в машину через консоль дашборда (VNC): пользователь `ubuntu`, пароль `cozystack`.
5. Впишите пароль базы. В дашборде откройте Secrets, секрет `postgres-demo-credentials`, ключ `appuser`, скопируйте значение. В машине откройте `/etc/app.env`, замените `REPLACE_ME_FROM_SECRET` на этот пароль и выполните `sudo systemctl restart app`.
6. Проверьте приложение: `curl -s localhost:8080/health` и `curl -s localhost:8080/items`.

Важно: пароль входа в машину `cozystack` лабораторный, для чего-то реального поменяйте его. Пароль базы в git не хранится, вы вписываете его сами на шаге 5. До шага 5 приложение будет перезапускаться с ошибкой подключения, это нормально: после того как впишете пароль и перезапустите сервис, оно подключится.

Остальная часть README описывает тот же результат через терминал, с SSH-ключом и скриптами, если вам так удобнее.

## Что понадобится

- Доступ к кластеру Cozystack и kubeconfig (переменная `KUBECONFIG`).
- Ваш тенант (namespace вида `tenant-<имя>`) с правами создавать приложения `apps.cozystack.io` (Postgres, VMDisk, VMInstance).
- Утилиты: `kubectl`, `virtctl`, `ssh-keygen`, `base64`.
- Доступ кластера в интернет для загрузки образа Ubuntu (`cloud-images.ubuntu.com`) и установки пакетов Python внутри машины.

Задайте переменную с именем вашего namespace, она используется во всех шагах:

```bash
export NS=tenant-<ваше-имя>
```

Примечание про `--validate=false`: на крупных кластерах клиентская загрузка схемы OpenAPI бывает медленной и `kubectl apply` подвисает. Флаг `--validate=false` отключает только клиентскую проверку схемы, сервер всё равно валидирует объект при приёме. Если у вас apply не подвисает, флаг можно не указывать.

## Шаг 1. Managed PostgreSQL

Манифест `manifests/01-postgres.yaml` создаёт базу `appdb` и пользователя `appuser` с правами администратора этой базы:

```bash
kubectl -n "$NS" apply --validate=false -f manifests/01-postgres.yaml
```

Дождитесь готовности: поле `Ready` у ресурса станет `True`, обычно 1-2 минуты, пока CloudNativePG поднимает два экземпляра.

```bash
kubectl -n "$NS" get postgres.apps.cozystack.io demo -w
```

Когда база готова, managed-Postgres создаёт секреты с реквизитами. Пароль пользователя `appuser` лежит в секрете `postgres-demo-credentials` под ключом `appuser`. Сервис для записи называется `postgres-demo-rw`.

## Шаг 2. Виртуальная машина с приложением

Сгенерируйте SSH-ключ, он нужен, чтобы заходить в машину:

```bash
ssh-keygen -t ed25519 -f ./lab_key -N ''
```

Запустите развёртывание. Скрипт сам прочитает пароль базы из секрета, соберёт cloud-init (код приложения и переменные подключения кладутся в машину через base64) и применит `VMDisk` и `VMInstance`:

```bash
NS="$NS" SSH_KEY_FILE=./lab_key.pub ./deploy.sh
```

Что произойдёт внутри машины при первом запуске (через cloud-init):

- Ставятся `python3-venv` и `python3-pip`.
- Создаётся virtualenv, в него ставятся Flask и psycopg.
- Поднимается systemd-сервис `app.service`, приложение слушает порт 8080.

Проследите за загрузкой. Важно: поле `Ready` у самого ресурса `VMInstance` становится `True` почти сразу, это готовность релиза, а не машины. Реальное состояние смотрите по импорту диска и фазе машины:

```bash
kubectl -n "$NS" get datavolume -w             # дождитесь Succeeded 100%
kubectl -n "$NS" get vmi vm-instance-app -w     # дождитесь Running и IP
```

После того как машина перешла в Running, подождите ещё около минуты, пока cloud-init доустанавливает пакеты и стартует приложение.

## Шаг 3. Проверка

Быстрая сквозная проверка одним скриптом: Postgres готов, машина запущена, приложение внутри машины пишет и читает базу.

```bash
NS="$NS" SSH_KEY=./lab_key ./check.sh
```

Ожидаемый результат: `health` возвращает `{"status":"ok"}`, `insert` создаёт новую запись, `items` возвращает список записей.

То же самое вручную. Зайдите в машину по SSH и обратитесь к приложению локально:

```bash
virtctl ssh ubuntu@vmi/vm-instance-app -n "$NS" --identity-file=./lab_key

# внутри машины:
curl -s localhost:8080/health
curl -s -X POST -H 'Content-Type: application/json' -d '{"name":"привет"}' localhost:8080/items
curl -s localhost:8080/items
```

Запись действительно попала в базу, а не осталась в памяти приложения. Это можно проверить напрямую через psql в поде Postgres:

```bash
PW=$(kubectl -n "$NS" get secret postgres-demo-credentials -o jsonpath='{.data.appuser}' | base64 -d)
kubectl -n "$NS" exec postgres-demo-1 -c postgres -- \
  env PGPASSWORD="$PW" psql -h postgres-demo-rw -U appuser -d appdb \
  -c 'SELECT id, name, created_at FROM items ORDER BY id;'
```

## Как это устроено

Приложение (`app/app.py`) не хранит строку подключения в коде. Оно вызывает `psycopg.connect()` без аргументов, а параметры берутся из стандартных переменных окружения libpq. Эти переменные лежат в файле `/etc/app.env` внутри машины:

```
PGHOST=postgres-demo-rw.<namespace>.svc
PGPORT=5432
PGUSER=appuser
PGPASSWORD=<из секрета postgres-demo-credentials>
PGDATABASE=appdb
```

Почему переменные libpq, а не URL вида `postgresql://...`: сгенерированный пароль может содержать символы (`/`, `@`, `:`), которые пришлось бы экранировать в URL. С отдельными переменными этой проблемы нет.

Почему машина видит базу: сервис `postgres-demo-rw` это обычный ClusterIP-сервис в вашем namespace. Виртуальная машина Cozystack работает в сети подов, поэтому из неё резолвится и доступно короткое имя сервиса внутри того же namespace. Полное имя `postgres-demo-rw.<namespace>.svc` работает отовсюду внутри кластера.

Файлы проекта:

- `manifests/01-postgres.yaml`: managed PostgreSQL (база `appdb`, пользователь `appuser`).
- `manifests/02-vm-disk.yaml`: диск машины из облачного образа Ubuntu по HTTP.
- `manifests/03-vm-instance.tpl.yaml`: шаблон машины, в cloud-init подставляются код, переменные и SSH-ключ.
- `manifests/00-tenant.yaml`: опционально, создание отдельного тенанта (обычно тенант у вас уже есть).
- `app/app.py`, `app/requirements.txt`: приложение на Flask и его зависимости.
- `deploy.sh`: рендер шаблона и применение ресурсов машины.
- `check.sh`: сквозная проверка.

## Уборка

Удалите ресурсы, когда закончите:

```bash
kubectl -n "$NS" delete vminstance.apps.cozystack.io app
kubectl -n "$NS" delete vmdisk.apps.cozystack.io app-disk
kubectl -n "$NS" delete postgres.apps.cozystack.io demo
```

Если создавали отдельный тенант из `00-tenant.yaml`, удалите и его (это удалит весь namespace тенанта вместе с содержимым):

```bash
kubectl -n tenant-root delete tenant.apps.cozystack.io practice
```

## Если что-то не так

- `kubectl apply` подвисает и падает с `failed to download openapi`: добавьте `--validate=false` (см. примечание выше).
- `VMInstance` показывает `Ready=True`, но приложение не отвечает: это готовность релиза, а не машины. Смотрите `datavolume` (импорт диска) и `vmi` (фаза машины), затем дайте cloud-init доработать.
- Приложение отвечает на `/health` ошибкой подключения к базе: проверьте, что Postgres в состоянии `Ready`, что имя сервиса в `/etc/app.env` совпадает с вашим namespace, и что пароль в секрете не менялся после развёртывания машины. Если меняли, перезапустите Шаг 2.
- `virtctl ssh` просит указывать тип цели: используйте форму `ubuntu@vmi/vm-instance-app`, как в примерах.
