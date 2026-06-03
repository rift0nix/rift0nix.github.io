---
title: "Сборка контейнерных образов через Docker Bake и Dagger"
date: 2026-06-03 12:00:00 +0300
categories: [Containers]
tags: [docker, dagger, github-actions, renovate]
image:
  path: https://i.postimg.cc/rp48zvkp/2026-06-03-dagger-bake-container-images.png
cover: https://i.postimg.cc/rp48zvkp/2026-06-03-dagger-bake-container-images.png
description: "Разберем подход к сборке и публикации OCI образов в монорепозитории через Docker Buildx Bake, Dagger и GitHub Actions"
author: [rift0nix]
---

Контейнерные образы часто начинают жить довольно просто. Есть Dockerfile, есть команда `docker build`, иногда рядом появляется `docker push`. Пока образ один, такой подход кажется нормальным. Но когда образов становится больше, появляются версии, несколько платформ, разные registry, автоматические обновления зависимостей и публикация из CI, простая команда постепенно превращается в набор договоренностей, которые нигде явно не описаны.

Хочется получить более предсказуемую схему:
1. Метаданные сборки лежат рядом с образом.
2. CI только запускает нужные проверки и публикацию.
3. Логика сборки не привязана к конкретному CI-провайдеру.
4. Версии зависимостей обновляются автоматически.
5. После публикации остается понятный release marker в git.

Для этого можно совместить Docker Buildx Bake и Dagger. Bake будет отвечать за декларативное описание образов, а Dagger - за выполнение сборки, проверки и публикации. Дальше покажу реализацию на примере репозитория [container-images](https://github.com/riftonix/container-images).

## Пример сборки hugo-autoprefixer

Первым образом в таком пайплайне будет `hugo-autoprefixer`. Он нужен для сборки статических сайтов, где используется Hugo extended и autoprefixer.

В этом примере рассматриваем два файла:
1. `docker/hugo-autoprefixer/Dockerfile` - описывает, из чего собирается контейнерный образ.
2. `docker/hugo-autoprefixer/docker-bake.json` - описывает build target, версии зависимостей, теги, labels и platforms.

Начнем с Dockerfile. Он небольшой:

```dockerfile
ARG HUGO_VERSION

FROM hugomods/hugo:exts-${HUGO_VERSION}

ARG AUTOPREFIXER_VERSION

RUN npm install --global "autoprefixer@${AUTOPREFIXER_VERSION}"
```

Что здесь происходит:
1. `ARG HUGO_VERSION` объявляется до `FROM`, потому что версия Hugo нужна для выбора базового образа.
2. Базовый образ берется из `hugomods/hugo` с тегом `exts-${HUGO_VERSION}`. Суффикс `exts` означает Hugo extended.
3. После `FROM` объявляется `ARG AUTOPREFIXER_VERSION`, потому что эта переменная используется уже внутри build stage.
4. Команда `npm install --global` устанавливает конкретную версию autoprefixer внутрь образа.

Dockerfile хорошо описывает, как собрать образ, но не всегда удобно хранить в нем всю внешнюю информацию о сборке. Например:
1. Какие build args используются для версии базового образа и npm-пакетов.
2. В какие registry и repository нужно публиковать образ.
3. Какие labels должны попасть в итоговый OCI образ.
4. Для каких платформ нужно выполнять сборку.
5. Какой тег считается релизным.

Все это можно передавать флагами в `docker build`, но тогда часть важной конфигурации начинает жить в CI. В результате GitHub Actions, GitLab CI или любой другой провайдер становятся не просто запускателем, а местом, где спрятана логика сборки.

Docker Buildx Bake решает эту проблему как стандартный формат описания build targets. В нашем случае для каждого образа будет свой `docker-bake.json`:

```text
docker/
  hugo-autoprefixer/
    Dockerfile
    docker-bake.json
```

Так образ становится самодостаточным: Dockerfile описывает слои, а `docker-bake.json` описывает контекст, аргументы, labels, platforms и итоговые теги.

Теперь посмотрим на начало `docker/hugo-autoprefixer/docker-bake.json`:

```json
{
  "variable": {
    "REGISTRY": {
      "default": "ghcr.io"
    },
    "REPOSITORY_PREFIX": {
      "default": "riftonix/container-images"
    },
    "HUGO_VERSION": {
      "default": "0.154.5",
      "description": "renovate: datasource=docker depName=hugomods/hugo extractVersion=^exts-(?<version>.+)$"
    },
    "AUTOPREFIXER_VERSION": {
      "default": "10.5.0",
      "description": "renovate: datasource=npm depName=autoprefixer"
    }
  }
}
```

Здесь есть две группы переменных.

Первая группа - runtime-настройки публикации:
1. `REGISTRY`
2. `REPOSITORY_PREFIX`

По умолчанию образ публикуется в `ghcr.io/riftonix/container-images` (эти значения при желании можно переопределить).

Вторая группа - версии зависимостей:
1. `HUGO_VERSION`
2. `AUTOPREFIXER_VERSION`

Именно эти значения попадут в Dockerfile как build args. Дополнительно у них есть `description` с метаданными Renovate. Благодаря этому Renovate понимает, что `HUGO_VERSION` нужно проверять по docker-тегам `hugomods/hugo`, а `AUTOPREFIXER_VERSION` - как npm-пакет `autoprefixer`.

Дальше в этом же файле описан сам target:

```json
{
  "target": {
    "hugo-autoprefixer": {
      "context": "docker/hugo-autoprefixer",
      "dockerfile": "Dockerfile",
      "args": {
        "HUGO_VERSION": "${HUGO_VERSION}",
        "AUTOPREFIXER_VERSION": "${AUTOPREFIXER_VERSION}"
      },
      "tags": [
        "${REGISTRY}/${REPOSITORY_PREFIX}/hugo-autoprefixer:${HUGO_VERSION}-${AUTOPREFIXER_VERSION}"
      ],
      "platforms": [
        "linux/amd64",
        "linux/arm64"
      ]
    }
  }
}
```

Этот блок связывает Dockerfile и параметры сборки:
1. `context` говорит, какую директорию передать в build.
2. `dockerfile` указывает файл относительно context.
3. `args` передает версии в Dockerfile.
4. `tags` описывает итоговый image reference.
5. `platforms` задает сборку под `linux/amd64` и `linux/arm64`.

Если подставить текущие значения переменных, тег образа получится таким:

```text
ghcr.io/riftonix/container-images/hugo-autoprefixer:0.154.5-10.5.0
```

В полном `docker-bake.json` target также содержит OCI labels:

```json
{
  "labels": {
    "org.opencontainers.image.title": "hugo-autoprefixer",
    "org.opencontainers.image.version": "${HUGO_VERSION}-${AUTOPREFIXER_VERSION}",
    "org.opencontainers.image.source": "https://github.com/riftonix/container-images",
    "org.opencontainers.image.base.name": "hugomods/hugo:exts-${HUGO_VERSION}",
    "io.riftonix.container-images.hugo.version": "${HUGO_VERSION}",
    "io.riftonix.container-images.autoprefixer.version": "${AUTOPREFIXER_VERSION}"
  }
}
```

Labels нужны не для сборки, а для нормальной трассируемости опубликованного образа. По ним можно понять, откуда образ был собран, какая версия Hugo использовалась как база и какая версия autoprefixer установлена внутрь.

В итоге `Dockerfile` отвечает только на вопрос "как собрать образ", а `docker-bake.json` отвечает на вопросы "с какими версиями", "под какие платформы", "с какими метаданными" и "куда публиковать".

Здесь есть важное ограничение: Dagger CI не поддерживает Docker Bake нативно как встроенный backend. Нельзя просто передать ему `docker-bake.json` и ожидать, что он сам выполнит target так же, как `docker buildx bake`.

Поэтому для этого репозитория реализуется отдельная логика в [Dagger Docker module](https://github.com/riftonix/daggerverse/blob/master/modules/docker/src/docker/main.py#L9). Она читает JSON Bake manifest, резолвит переменные, выбирает нужный target и переводит поддержанные поля Bake в Dagger-native API сборки. В результате `docker-bake.json` остается источником правды для описания образа, но сама сборка выполняется через Dagger без зависимости от Docker socket, Buildx builder и CLI-окружения конкретного CI.

## Итоговая схема

Самая важная часть подхода - правильно разделить ответственность.

Bake описывает build target:
1. context
2. Dockerfile
3. build args
4. labels
5. platforms
6. tags

Dagger выполняет операции:
1. читает Bake manifest
2. резолвит переменные
3. собирает образ через Dagger-native API
4. проверяет образ без публикации
5. публикует все разрешенные ссылки на образы
6. отдает release tag для git

GitHub Actions только решает, когда запускаться:
1. на pull request - verify
2. на push в master - publish
3. после успешной публикации - создать git tag marker

То есть workflow остается тонким. В нем есть checkout, секреты, условия запуска и вызов Dagger. Вся логика сборки остается в переиспользуемых Dagger-модулях и scenario.

В этом пайплайне используются:
1. [Dagger Docker module](https://github.com/riftonix/daggerverse/tree/master/modules/docker) - читает Bake manifest, резолвит target и собирает OCI образ через Dagger-native API.
2. [Dagger container-images scenario](https://github.com/riftonix/daggerverse/tree/master/scenarios/container-images) - дает CI функции для верификации и публикации.
3. [Dagger Git module](https://github.com/riftonix/daggerverse/tree/master/modules/git) - создает или подтверждает git tag после успешной публикации.

Итоговый пайплайн получается следующим.

На pull request:
1. GitHub Actions вызывает `make changed-components`, а тот через Git module определяет измененные директории `docker/*` и shared-файлы вроде workflow, `renovate.json` и Makefile.
2. Workflow вызывает Dagger verify для нужного Bake target.
3. Dagger читает `docker-bake.json` и собирает образ без публикации.
4. Aggregation job `CI Passed` становится единой required-проверкой.

На push в master:
1. GitHub Actions запускает publish workflow.
2. Dagger настраивает registry auth.
3. Dagger собирает Bake target и публикует разрешенные ссылки на образы.
4. Dagger получает release marker из метаданных Bake.
5. [Git-модуль](https://github.com/riftonix/daggerverse/tree/master/modules/git) создает или подтверждает git tag.

Локально проверить сборку можно без учетных данных registry:

```sh
make verify docker/hugo-autoprefixer
```

Для проверки publish-сценария без реальной отправки образа есть отдельный пробный запуск:

```sh
make publish-dry-run docker/hugo-autoprefixer
```

Реальная публикация требует параметры для registry и git. Для GHCR достаточно передать имя пользователя и токен через `GITHUB_TOKEN`:

```sh
GITHUB_TOKEN="$(gh auth token)" \
  make publish docker/hugo-autoprefixer REGISTRY_USERNAME=<github-username>
```

По умолчанию `GITHUB_TOKEN` используется и как пароль для GHCR, и как токен для push release tag в git. При необходимости имена env-переменных можно переопределить через `REGISTRY_PASSWORD_ENV` и `GIT_TOKEN_ENV`.

Отмечу, запуск через make - не отдельный локальный запуск, а та же точка входа, которая используется в GitHub Actions. Локальный запуск `make verify`, `make publish-dry-run` или `make publish` полностью эквивалентен запуску из workflow: отличаются только источник секретов и значения переменных окружения.

## Почему не просто docker buildx bake --push?

На первый взгляд можно было бы запускать `docker buildx bake --push` прямо в CI. Но тогда пайплайн начинает зависеть от Docker socket, buildx builder, CLI-аутентификации и особенностей окружения конкретного CI.

В этом подходе Bake используется как уже стандартизированный манифест, но не как обязательный механизм выполнения сборки. Dagger-модуль читает `docker-bake.json`, получает из него метаданные и переводит поддержанные поля в обычные вызовы сборки Dagger.

Здесь важно честно проговорить ограничение. Мы берем стандартный формат Docker Bake, но не реализуем полную поддержку всего, что умеет `docker buildx bake`. В Dagger-модуле поддержаны только те поля, которые нужны текущему пайплайну:
1. `context`
2. `dockerfile`
3. `args`
4. `tags`
5. `labels`
6. `platforms`

То есть Bake здесь используется прежде всего как готовый формат описания образов, а не как полностью воспроизведенная реализация Buildx внутри Dagger. Если в Bake target появится неподдержанное поле, модуль должен упасть с понятной ошибкой. Это лучше, чем молча проигнорировать часть конфигурации и собрать не тот образ.

## Git tags как release markers

После успешной публикации хочется оставить след не только в registry, но и в git. Для этого используется тег вида:

```text
docker/hugo-autoprefixer/0.154.5-10.5.0
```

Важно, что тег создается после публикации, а не запускает публикацию. Это именно marker, который говорит: такая версия образа уже успешно опубликована.

## Renovate для операционных зависимостей

Еще одна важная часть - автоматические обновления. В репозитории есть различные версии:
1. версия Dagger CLI в workflow
2. версии GitHub Actions
3. версии released Dagger modules и scenarios
4. версия Hugo в Bake manifest
5. версия autoprefixer в Bake manifest

Все эти зависимости должны быть покрыты Renovate. Для GitHub Actions достаточно built-in manager. Для Dagger CLI и released daggerverse refs нужны custom managers. Для Hugo и autoprefixer версии хранятся в Bake variables, а метаданные Renovate добавляются в descriptions прямо внутри `docker-bake.json`.

За счет этого обновление базового образа или autoprefixer не требует ручного редактирования Dockerfile. Renovate меняет версию в Bake manifest, pull request проходит обычный verify pipeline, а после merge publish workflow выпускает новый образ и ставит release marker.

## Заключение

В такой схеме Docker Bake становится стандартным manifest-форматом для описания образов, Dagger - переносимым runtime для сборки и публикации, а GitHub Actions - тонким слоем запуска. В итоге получается монорепозиторий для хранения самообновляющихся базовых образов: каждый образ живет в своей директории, версии управляются декларативно и обновляются через Renovate, публикация не размазана по CI, а успешный релиз фиксируется отдельным git tag.

Образ `hugo-autoprefixer` небольшой, но именно он наглядно демонстрирует всю платформу для сборки образов: сборка по метаданным Bake, публикация, релизные теги и автообновления. После этого добавление новых образов сводится к новой директории в `docker/`, Dockerfile и локальному `docker-bake.json`.
