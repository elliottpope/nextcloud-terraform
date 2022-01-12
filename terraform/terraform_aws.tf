terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
      version = "3.6.0"
    }
    random = {
      source = "hashicorp/random"
      version = "3.1.0"
    }
  }
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "nextcloud_data_root_dir" {
  type = string
}

variable "root_domain" {
  type = string
}

variable "ssh_key_name" {
  type = string
}

# Configure the AWS Provider
provider "aws" {
  region = var.aws_region
}

provider "cloudflare" {
  # Provide an API Token with DNS:Edit permissions on var.root_domain in the environment as CLOUDFLARE_API_TOKEN
}

provider "random" {
  # Configuration options
}

# We require an AMI with Docker already installed, an existing VPC, a personal SSH key, and a security group which allows inbound SSH access
data "aws_ami" "ubuntu-docker" {
  owners      = ["self"]
  most_recent = true
  name_regex  = "nomad-base-image"
}

data "aws_key_pair" "personal-ssh-key" {
  key_name = "${var.ssh_key_name}"
}

data "aws_security_group" "ssh-access" {
  name = "Personal SSH Access"
}

data "aws_vpc" "vpc" {
  default = true
}

# Generate the secure random passwords and usernames for Postgres, Redis, and the Nextcloud Admin account
resource "random_pet" "postgres_username" {
  length = 1
}

resource "random_password" "postgres_password" {
  length = 12
  special = false
}

resource "random_password" "redis_password" {
  length = 12
  special = false
}

resource "random_password" "nextcloud_admin_password" {
  length = 12
  special = false
}

# We then build the security groups for public HTTP/S access, internal DB access, and internal EFS access
resource "aws_security_group" "http_access" {
  name = "Public HTTP/S Access"
  description = "Allows public access to on standard HTTP and HTTPS TCP ports"
  ingress {
    description = "Allow Public HTTP access on port 80"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [ "0.0.0.0/0" ]
    ipv6_cidr_blocks = [ "::/0" ]
  }
  ingress {
    description = "Allow Public HTTPS access on port 443"
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = [ "0.0.0.0/0" ]
    ipv6_cidr_blocks = [ "::/0" ]
  }
  egress {
    description = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  tags = {
    Scope = "public",
    Protocol = "http(s)"
  }
}

resource "aws_security_group" "db_access" {
  name = "VPC PostgreSQL Access"
  description = "Allows access within the VPC to PostgreSQL instances on port 5432"
  ingress {
    description = "Allow VPC access on port 80"
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
    ipv6_cidr_blocks = data.aws_vpc.vpc.ipv6_cidr_block == null ? [] : [data.aws_vpc.vpc.ipv6_cidr_block]
  }
  egress {
    description = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  tags = {
    Scope = "private",
    Protocol = "postgres"
  }
}

# Then we build the EBS volume where our Nextcloud data and certificates will be persisted and mount it to the EC2
resource "aws_ebs_volume" "nextcloud_data" {
  availability_zone = "${aws_instance.nextcloud.availability_zone}"
  encrypted = false
  size = 22
  type = "gp2"
  tags = {
    Name = "Nextcloud Data",
    Project = "nextcloud"
  }
}

# Then we build the EC2 where Nextcloud will run 
resource "aws_instance" "nextcloud" {
  ami           = data.aws_ami.ubuntu-docker.image_id
  instance_type = "t3.micro"
  root_block_device {
    delete_on_termination = true
    volume_type           = "gp2"
    volume_size           = 8
    encrypted             = false
  }
  key_name = data.aws_key_pair.personal-ssh-key.key_name
  tags = {
    Name = "Nextcloud Server"
    Project = "nextcloud"
  }
  security_groups = [
    aws_security_group.http_access.name,
    data.aws_security_group.ssh-access.name,
    aws_security_group.db_access.name
  ]

  connection {
    type = "ssh"
    user = "ubuntu"
    host = "${self.public_dns}"
    private_key = "${file("${path.module}/private_key.pem")}"
  }

  # Then we create and copy in the NGINX configuration
  provisioner "file" {
    source = "../nginx.conf"
    destination = "/home/ubuntu/nginx.conf"
  }

  provisioner "file" {
    source = "../nginx-acme.conf"
    destination = "/home/ubuntu/nginx-acme.conf"
  }

  # Then we create and copy in the Nextcloud configuration
  provisioner "file" {
    content = <<-EOT
    POSTGRES_HOST=${aws_db_instance.metadata_db.address}
    POSTGRES_USER=${random_pet.postgres_username.id}
    POSTGRES_PASSWORD=${random_password.postgres_password.result}
    POSTGRES_DB=nextcloud
    NEXTCLOUD_ADMIN_USER=admin
    NEXTCLOUD_ADMIN_PASSWORD=${random_password.nextcloud_admin_password.result}
    NEXTCLOUD_TRUSTED_DOMAINS=localhost nextcloud.${var.root_domain} www.nextcloud.${var.root_domain}
    REDIS_HOST=redis
    REDIS_HOST_PASSWORD=${random_password.redis_password.result}
    EOT
    destination = "/home/ubuntu/nextcloud.env"
  }

  # Then we copy up a utility script to format and mount the EBS volume
    provisioner "file" {
    source = "../format-and-mount-ebs.sh"
    destination = "/home/ubuntu/format-and-mount-ebs.sh"
  }

  # Then we copy up the script to initialize the SSL configuration and make it executable
  provisioner "file" {
    source = "../init-letsencrypt.sh"
    destination = "/home/ubuntu/init-letsencrypt.sh"
  }

  provisioner "remote-exec" {
    inline = [  
      "sudo chmod +x /home/ubuntu/init-letsencrypt.sh",
      "sudo chmod +x /home/ubuntu/format-and-mount-ebs.sh",
    ]
  }

  # Then set any required environment variables system wide
  provisioner "remote-exec" {
    inline = [  
      "echo NEXTCLOUD_DATA_DIR=\"${var.nextcloud_data_root_dir}\" | sudo tee -a /etc/environment > /dev/null",
      "echo DOMAIN=\"${var.root_domain}\" | sudo tee -a /etc/environment > /dev/null"
    ]
  }
}

# Then we associate the EBS volume with the EC2 instance
resource "aws_volume_attachment" "nextcloud_data_mount" {

  device_name = "/dev/sdf"
  volume_id = aws_ebs_volume.nextcloud_data.id
  instance_id = aws_instance.nextcloud.id

  connection {
    type = "ssh"
    user = "ubuntu"
    host = "${aws_eip.static_ip.public_dns}"
    private_key = "${file("${path.module}/private_key.pem")}"
  }

  # Then we create and copy in the docker-compose.yml file 
  # since the mount directory may change (see https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/device_naming.html#device-name-limits)
  #   the docker-compose.yml must be uploaded after the volume has been successfully mounted so that we have access
  #   to the mount point location.
  provisioner "file" {
    content = <<-EOT
    version: '3'

    services:
      nextcloud:
        image: nextcloud:23-fpm-alpine
        env_file:
          - nextcloud.env
        volumes:
          - $${NEXTCLOUD_DATA_DIR}/nextcloud:/var/www/html
      proxy:
        image: nginx:1.21-alpine
        command: "/bin/sh -c 'while :; do sleep 6h & wait $$${!}; nginx -s reload; done & nginx -g \"daemon off;\"'"
        ports:
          - 80:80
          - 443:443
        volumes:
          - ./nginx.conf:/etc/nginx/nginx.conf:ro
          - $${NEXTCLOUD_DATA_DIR}/nextcloud:/var/www/html
          - $${NEXTCLOUD_DATA_DIR}/certbot/conf:/etc/letsencrypt
          - $${NEXTCLOUD_DATA_DIR}/certbot/www:/var/www/certbot
      nextcloud-cron:
        image: nextcloud:23-fpm-alpine
        env_file:
          - nextcloud.env
        volumes:
          - $${NEXTCLOUD_DATA_DIR}/nextcloud:/var/www/html
        entrypoint: /cron.sh
      redis:
        image: redis:6.2-alpine
        command: redis-server --requirepass ${random_password.redis_password.result}
      certbot:
        image: certbot/certbot:v1.22.0
        entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $$${!}; done;'"
        volumes:
          - $${NEXTCLOUD_DATA_DIR}/certbot/conf:/etc/letsencrypt
          - $${NEXTCLOUD_DATA_DIR}/certbot/www:/var/www/certbot
    EOT
    destination = "/home/ubuntu/docker-compose.yml"
  }

  # Then we create and copy in the docker-compose.yml file to initialize the certificates
  # since the mount directory may change (see https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/device_naming.html#device-name-limits)
  #   the docker-compose.yml must be uploaded after the volume has been successfully mounted so that we have access
  #   to the mount point location.
  provisioner "file" {
    content = <<-EOT
    version: '3'

    services:
      nginx:
        image: nginx:1.21-alpine
        ports:
          - 80:80
        volumes:
          - ./nginx-acme.conf:/etc/nginx/nginx.conf:ro
          - $${NEXTCLOUD_DATA_DIR}/certbot/conf:/etc/letsencrypt
          - $${NEXTCLOUD_DATA_DIR}/certbot/www:/var/www/certbot
      certbot:
        image: certbot/certbot:v1.22.0
        volumes:
          - $${NEXTCLOUD_DATA_DIR}/certbot/conf:/etc/letsencrypt
          - $${NEXTCLOUD_DATA_DIR}/certbot/www:/var/www/certbot
    EOT
    destination = "/home/ubuntu/init-certificates.yml"
  }

  # TODO: format and mount EBS using script (lsblk, ./format-and-mount-ebs.sh <device name> ${NEXTCLOUD_DATA_DIR})
  # TODO: run init certificates scripts (./init-letsencrypt.sh ${NEXTCLOUD_DATA_DIR}/certbot <email>)
  # TODO: run docker-compose up
}

# Then we provision an Elastic IP so that we will have a static IP to reference in the DNS record
resource "aws_eip" "static_ip" {
  instance = aws_instance.nextcloud.id
}

# Then we provision the PostgreSQL database that will store the metadata
resource "aws_db_instance" "metadata_db" {
  allocated_storage   = 20
  engine              = "postgres"
  engine_version      = "12"
  instance_class      = "db.t2.micro"
  identifier          = "nextcloud-db"
  username            = "${random_pet.postgres_username.id}"
  password            = "${random_password.postgres_password.result}"
  name                = "nextcloud"
  skip_final_snapshot = true
  multi_az            = false
  storage_type        = "gp2"
  vpc_security_group_ids = [
    aws_security_group.db_access.id,
  ]
  tags = {
    Project = "nextcloud"
  }
}

resource "cloudflare_record" "nextcloud_domain_name" {
  zone_id = var.cloudflare_zone_id
  name    = "nextcloud"
  value   = "${aws_eip.static_ip.public_dns}"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "cloudflare_record" "www_nextcloud_domain_name" {
  zone_id = var.cloudflare_zone_id
  name    = "www.nextcloud"
  value   = "${aws_eip.static_ip.public_dns}"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

output "nextcloud_server" {
  value = aws_eip.static_ip.public_dns
}

output "postgres_username" {
  value = random_pet.postgres_username.id
  sensitive = true
}

output "redis_password" {
  value = random_password.redis_password.result
  sensitive = true
}

output "nextcloud_admin_password" {
  value = random_password.nextcloud_admin_password.result
  sensitive = true
}
