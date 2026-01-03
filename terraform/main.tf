terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 6.19"
    }
  }

  required_version = ">= 1.2"
}

provider "aws" {
  region = "us-east-1"
}
