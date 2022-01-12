# Deploying Nextcloud using Terraform

Scripts for deploying Nextcloud using Packer, Terraform, and Docker Compose.

## Prerequisites

- An AWS account and AWS credentials configured locally (using `aws configure`) with permissions to create/destroy EC2, EBS, RDS, and Elastic IPs
- A Cloudflare account with an existing registered domain and an API Token with `DNS:Edit` permissions
- An AWS VPC, SSH Key Pair in AWS EC2, and a security group which allows SSH access from your local machine
- [HashiCorp Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli?in=terraform/aws-get-started) and [HashiCorp Packer](https://learn.hashicorp.com/tutorials/packer/get-started-install-cli?in=packer/aws-get-started) preinstalled

## Getting Started

### Building the AMI

This script requires an AMI with Docker and Docker Compose preinstalled. You can build this image using [HashiCorp Packer](https://learn.hashicorp.com/tutorials/packer/get-started-install-cli?in=packer/aws-get-started)

The following commands will prepare and build the required AMI:
```
cd packer
packer init .
packer fmt .
packer validate .
packer build .
```

### Prepare the Terraform Scripts

These Terraform scripts require SSH access to the EC2 instance to copy up the scripts and manifests, and also to run commands to prepare the environment

```
cp <path to your ssh key> ./terraform/private_key.pem
chmod 400 ./terraform/private_key.pem
```

### Running the Terraform Scripts

The following commands will prepare and run the Terraform scripts:

```
cd terraform
terraform init 
terraform plan -var-file terraform_aws.tfvars -out terraform.plan
terraform apply -auto-approve terraform.plan
```

### Configuring the EC2 instances

The EC2 instances will still require some manual configuration after creation to format and mount the EBS volume

```
ssh -i ./private_key.pem ubuntu@$(terraform output nextcloud_server)
```

Find the name of the EBS device using `lsblk`. It is likely named `/dev/sdf`, `/dev/xvdf`, or `/dev/nvme1n1`

Then run the following to format and mount the EBS volume, and create the SSL certificates:

```
./format-and-mount-ebs.sh <device name, i.e. /dev/nvme1n1> ${NEXTCLOUD_DATA_DIR}
./init-letsencrypt.sh ${NEXTCLOUD_DATA_DIR}/certbot <email>
```

### Running Nextcloud

You may now use `docker-compose up -d` to start up Nextcloud and all related services

Verify that it is running correctly using `docker ps` to verify that `ubuntu_proxy_1` is running and exposes TCP port 80 and 443. Additionally, running `curl -L http://localhost -v` should redirect to HTTPS and return an HTML document

Finally, you can visit `http://nextcloud.elliottpope.com` to login

### Admin Setup

Nextcloud is created with an admin account with a password you can find using `terraform output nextcloud_admin_password`. You should log in with that account, install any apps you want to use, and create your personal user and any other user accounts.

## Tearing Down the Infrastructure

You can tear down everything using `terraform destroy -var-file terraform_aws.tfvars -auto-approve` 
