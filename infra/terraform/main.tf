module "networking" {
  source = "./modules/networking"

  project                  = var.project
  environment              = var.environment
  vpc_cidr                 = var.vpc_cidr
  azs                      = var.azs
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs
}

module "security" {
  source = "./modules/security"

  project     = var.project
  environment = var.environment
  vpc_id      = module.networking.vpc_id
  my_ip_cidr  = var.my_ip_cidr
}

module "compute" {
  source = "./modules/compute"

  project     = var.project
  environment = var.environment

  ami_id                = var.ami_id
  key_name              = var.key_name
  public_key_path       = var.public_key_path
  bastion_instance_type = var.bastion_instance_type
  app_instance_type     = var.app_instance_type

  public_subnet_ids      = module.networking.public_subnet_ids
  private_app_subnet_ids = module.networking.private_app_subnet_ids
  private_db_subnet_ids  = module.networking.private_db_subnet_ids

  bastion_sg_id  = module.security.bastion_sg_id
  frontend_sg_id = module.security.frontend_sg_id
  backend_sg_id  = module.security.backend_sg_id
  db_sg_id       = module.security.db_sg_id
}
