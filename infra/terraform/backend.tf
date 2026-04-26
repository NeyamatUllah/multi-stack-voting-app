terraform {
  backend "s3" {
    bucket       = "voting-app-tfstate-20260426-ney"
    key          = "voting-app/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
