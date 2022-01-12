packer {
  required_plugins {
    amazon = {
      version = ">= 0.0.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "ami-name" {
  type    = string
  default = "nomad-base-image"
}

variable "aws_region" {
  type = string
}

variable "base_ami" {
  type    = string
  default = "ami-0ac10f53765369588"
}

source "amazon-ebs" "ubuntu" {
  ami_name      = "${var.ami-name}"
  instance_type = "t2.micro"
  region        = "${var.aws_region}"
  source_ami    = "${var.base_ami}"
  ssh_username  = "ubuntu"
}

build {
  name = "nomad-base-ami"
  sources = [
    "source.amazon-ebs.ubuntu"
  ]
  tags = [
    Name = "Ubuntu with Docker, Docker Compose, and NFS"
  ]


  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = [
      "echo Updating System",
      "sudo apt-get update && sudo apt-get -y upgrade && sudo apt-get -y autoremove"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = [
      "echo Installing Docker",
      "sudo apt-get install ca-certificates curl gnupg lsb-release",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --no-tty --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get update &&  sudo apt-get install -y docker-ce docker-ce-cli containerd.io",
      "docker --version",
      "sudo usermod -aG docker $USER",
      "sudo newgrp docker"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo Installing Docker Compose",
      "sudo curl -L \"https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose",
      "sudo chmod +x /usr/local/bin/docker-compose",
      "docker-compose --version"
    ]
  }
}