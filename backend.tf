terraform {
  backend "s3" {
    bucket       = "example-voting-app-terraform-state"
    key          = "example-voting-app/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = false
  }
}
