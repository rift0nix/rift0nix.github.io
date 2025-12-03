---
title: "Простая выписка сертификата для dns через terraform"
date: 2025-11-18 13:00:00 +0300
categories: [Terraform]
tags: [terraform, acme]
image:
  path: https://i.postimg.cc/zXdGtyXT/automatic-acme-certs-via-terraform.png
cover: https://i.postimg.cc/zXdGtyXT/automatic-acme-certs-via-terraform.png
description: "В этом посте выпишем сертификат для dns имени, посмотрим как его продлевать, и все это без использования виртуальных машин"
author: [rift0nix]
mermaid: true
---

Сертификаты - слово, которое почти наверняка вызывает боль у инженера. Где и как их взять? Как настроить под них систему? А где хранить? Как продлевать? Попробуем выстроить универсальный подход работы с сертификатами в случае, когда практически нет инфраструктуры (или вовсе отсутствует), но хочется начать с ними работать без особых сложностей.


## Что будем делать?

Сертификат будем получать у Let's Encrypt по ACME протоколу. Идея следующая:
1. Клиент (в нашем случае сценарий, запущенный через terraform) создает аккаунт и генерирует запрос на сертификат.
2. Let's Encrypt проверяет, что вы контролируете домен. Есть разные проверки, мы создадим специальную dns-запись для домена
3. После успешной проверки Let's Encrypt автоматически выдает сертификат, мы сохраним его в стейт локально. При желании возможна настройка сохранения стейта в удаленное хранилище
4. Проверим, что сертификат продляется по истечению заданного периода

## Подготовка к работе

Для воспроизведения работы с сертификатом понадобится сделать небольшую подготовку.

### Настройка окружения

Нам понадобятся
1. Установленный [Opentofu](https://opentofu.org/docs/intro/install/) (форк Terraform).
2. Аккаунт в облаке [Timeweb](https://timeweb.cc)


### Создание домена

Если нет своего домена, можно завести прям в облаке. После регистрации заходите в [панель управления доменами](https://timeweb.cc/my/domains/move) и заводите домен в любой из зон:
- .tw1.su
- .tw1.ru
- .webtm.ru
- .twc1.net

Для примера выпишем сертификат для example-test.tw1.su

### Создание токена для terraform

Для работы через тераформ создайте свой токен в разделе [API и Terraform](https://timeweb.cloud/my/api-keys/create).
Сохраните ваш timeweb токен в переменную окружения TF_VAR_timeweb_token

## Создание клиента

Итак, пришло время время автоматизации. Создайте файл dns.tf, всю дальнейшую работу будем вести в нем. Для начала опишем провайдеры.

### Настройка провайдеров

Нам понадобятся:
1. [Провайдер от timeweb](https://registry.terraform.io/providers/timeweb-cloud/timeweb-cloud/latest/docs) для взаимодействия с облаком
2. [Провайдер для создания tls ключей](https://registry.terraform.io/providers/hashicorp/tls/latest) для создания acme регистрации и для выписки сертификата
3. [Acme провайдер](https://registry.terraform.io/providers/vancluever/acme/latest/docs) для прохождения проверки и получения сертификата

Также убедитесь, что ваш timeweb токен сохранен в TF_VAR_timeweb_token

```hcl
terraform {
  required_providers {
    twc = {
      source  = "tf.timeweb.cloud/timeweb-cloud/timeweb-cloud"
      version = "1.6.6"
    }
    tls = {
      source = "hashicorp/tls"
      version = "4.1.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "2.38.0"
    }
  }
}

variable "timeweb_token" {
  description = "Timeweb cloud token, more info https://github.com/timeweb-cloud/terraform-provider-timeweb-cloud/tree/main"
  type        = string
  sensitive   = true
}

provider "twc" {
  token = var.timeweb_token
}

provider "acme" {
  server_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
}
```
Обратите внимание, что в провайдере acme мы используем стейджовый сервер:
```
https://acme-staging-v02.api.letsencrypt.org/directory
```

В то время как адрес основного сервера:
```
https://acme-v02.api.letsencrypt.org/directory
```

В чем разница между серверами?
1. Различные rate limits у [prod](https://letsencrypt.org/docs/rate-limits/) и [stage](https://letsencrypt.org/docs/staging-environment/). Например, перевыписка сертификата для тех же доменных имен на prod возможна 5 раз в неделю, а на stage 30000 раз в неделю
2. Браузеры и ОС не доверяют по умолчанию сертификатам со stage сервера, хотя по-прежденему можно добавлять эти сертификаты в доверенные вручную. С prod сервера доверие настроено по умолчанию.

Таким образом, для тестов пользуемся stage. Далее для боевых задач адрес нужно поменять на prod-овый.

### Регистрируемся в let's encrypt

Для регистрации нам потребуется RSA ключ и собственно сам запрос регистрации

```hcl
resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "this" {
  email_address   = "example@gmail.com"
  account_key_pem = tls_private_key.acme_account.private_key_pem
}
```


### Получаем сертификат для домена

```hcl
resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "this" {
  private_key_pem = tls_private_key.this.private_key_pem
  dns_names       = ["example-test.tw1.su", "*.example-test.tw1.su"]

  subject {
    common_name = "example-test.tw1.su"
  }
}

resource "acme_certificate" "this" {
  account_key_pem           = acme_registration.this.account_key_pem
  certificate_request_pem   = tls_cert_request.this.cert_request_pem
  min_days_remaining        = 30

  dns_challenge {
    provider = "timewebcloud"

    config = {
      TIMEWEBCLOUD_AUTH_TOKEN = var.timeweb_token
    }
  }
}

output "acme_certificate_this" {
  value = acme_certificate.this
  sensitive = true
}
```

Что здесь происходит
1. Сначала выписываем новый приватный RSA ключ
2. Далее создаем CSR (Certificate Signing Request). По сути это описание, какой сертификат мы хотим получить. Так мы сами контролируем, какие поля попадут в сертифкат. И что важнее, мы нигде не светим приватный ключ от сертификата
3. И наконец ресурс acme_certificate, который непосредственно отправляет запрос и получает подписанный сертификат от let's encrypt.

Теперь, чтобы получить сертификат, просто выполните
```bash
tofu apply
```

Чтобы посмотреть, какой сертификат пришел, выполните
```bash
tofu output acme_certificate_this
```
Сертификат будет лежать в certificate_pem

Полностью готовый манифест можно скачать по [ссылке](../../assets/files/2025-11-18-acme-dns.tf)

### Контроль времени жизни сертификата

Сейчас в ресурсе acme_certificate задан параметр min_days_remaining = 30. Это значит, что за 30 дней до истечения сертификата при выполении tofu apply будет перевыписываться сертификат. Как проверить, что это работает? Сделайте значение min_days_remaining = 90, так сертификат будет перевыписываться всякий раз, когда будет проходить apply. Перевыписку можно автоматизировать. Самый простой способ, выполнять tofu apply -auto-approve по расписанию.

## Заключение

Использование terraform (или opentofu) совместно с ACME позволяет позволяет полностью автоматизировать работу с tls сертификатами. В результате выпуск и продление сертификатов превращаются в декларативно описанный сценарий, который можно по расписанию запускать в любой CI/CD системе. Получение сертификата возможно до создания какой-либо реальной инфраструктуры, что дает возможность с нуля начать пользоваться зашифрованными соединениями. Такой подход:
- экономит время
- повышает безопасность
- снижает риски ошибок
- масштабируется под различные цели и задачи

С таким подходом создание инфраструктуры с нуля в облаке становится немного легче.