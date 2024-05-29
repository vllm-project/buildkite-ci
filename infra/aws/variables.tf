terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.3"
    }
    buildkite = {
      source  = "buildkite/buildkite"
      version = "0.19.1"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

provider "buildkite" {
  organization = "vllm"
}

variable "elastic_ci_stack_version" {
  type    = string
  default = "6.21.0"
}