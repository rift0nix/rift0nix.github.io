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


resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "this" {
  email_address   = "example@gmail.com"
  account_key_pem = tls_private_key.acme_account.private_key_pem
}

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
