# ==========================================
# VARIABLES
# ==========================================
variable "region" {
  description = "AWS Region"
  default     = "us-east-1"
}

variable "key_name" {
  description = "Name of the existing AWS Key Pair to SSH into instances"
  type        = string
  default     = "vicky0" 
}

variable "jenkins_instance_type" {
  description = "Instance type for Jenkins"
  default     = "c7i-flex.large"
}

variable "tomcat_instance_type" {
  description = "Instance type for Tomcat"
  default     = "t3.small"
}

# ==========================================
# PROVIDER
# ==========================================
provider "aws" {
  region = var.region
}

# ==========================================
# NETWORKING
# ==========================================
resource "aws_vpc" "cicd_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "CICD-VPC" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.cicd_vpc.id
  tags = { Name = "CICD-IGW" }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.cicd_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"
  tags = { Name = "CICD-Public-Subnet" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.cicd_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "CICD-Public-RT" }
}

resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# ==========================================
# SECURITY GROUPS
# ==========================================
resource "aws_security_group" "jenkins_sg" {
  name        = "Jenkins-SG"
  description = "Allow SSH and Jenkins UI"
  vpc_id      = aws_vpc.cicd_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "Jenkins-SG" }
}

resource "aws_security_group" "tomcat_sg" {
  name        = "Tomcat-SG"
  description = "Allow SSH, Tomcat UI, and HTTP"
  vpc_id      = aws_vpc.cicd_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Tomcat UI/App"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "Tomcat-SG" }
}

# ==========================================
# FETCH LATEST UBUNTU AMI
# ==========================================
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] 
  
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ==========================================
# EC2 INSTANCE 1: JENKINS (WITH SUDO)
# ==========================================
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.jenkins_instance_type
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]
  key_name               = var.key_name

  user_data = <<-EOF
              #!/bin/bash
              set -e
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              sudo apt-get update -y
              sudo apt-get install -y openjdk-21-jdk curl gnupg

              sudo curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
              sudo bash -c 'echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/ | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null'

              sudo apt-get update -y
              sudo apt-get install -y jenkins

              sudo apt-get install -y docker.io
              sudo usermod -aG docker jenkins

              sudo systemctl daemon-reload
              sudo systemctl restart jenkins

              echo "=========================================" >> /var/log/user-data.log
              echo "JENKINS INITIAL ADMIN PASSWORD:" >> /var/log/user-data.log
              sudo cat /var/lib/jenkins/secrets/initialAdminPassword >> /var/log/user-data.log
              echo "=========================================" >> /var/log/user-data.log
              EOF

  tags = { Name = "Jenkins-Server" }
}

# ==========================================
# EC2 INSTANCE 2: TOMCAT (WITH SUDO)
# ==========================================
resource "aws_instance" "tomcat" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.tomcat_instance_type
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.tomcat_sg.id]
  key_name               = var.key_name

  user_data = <<-EOF
              #!/bin/bash
              set -e
              exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
              
              sudo apt-get update -y
              sudo apt-get install -y openjdk-17-jdk docker.io
              sudo usermod -aG docker ubuntu

                        # 1. Dynamically find the latest version number
            TOMCAT_VER=$(curl -s https://downloads.apache.org/tomcat/tomcat-10/ | grep -oE 'v10\.[0-9]+\.[0-9]+' | head -n1 | sed 's/v//')

            # 2. Download, extract, and move to /opt/tomcat
            sudo wget "https://dlcdn.apache.org/tomcat/tomcat-10/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz" -P /tmp
            sudo tar -xzf "/tmp/apache-tomcat-${TOMCAT_VER}.tar.gz" -C /opt
            sudo mv "/opt/apache-tomcat-${TOMCAT_VER}" /opt/tomcat
              sudo bash -c 'cat << EOXML > /opt/tomcat/webapps/manager/META-INF/context.xml
              <?xml version="1.0" encoding="UTF-8"?>
              <Context antiResourceLocking="false" privileged="true" >
                <!--
                <Valve className="org.apache.catalina.valves.RemoteAddrValve"
                       allow="127\.\d+\.\d+\.\d+|::1|0:0:0:0:0:0:0:1" />
                -->
              </Context>
              EOXML'

              sudo bash -c 'cat << EOXML > /opt/tomcat/conf/tomcat-users.xml
              <?xml version="1.0" encoding="UTF-8"?>
              <tomcat-users xmlns="http://tomcat.apache.org/xml"
                          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                          xsi:schemaLocation="http://tomcat.apache.org/xml tomcat-users.xsd"
                          version="1.0">
                <role rolename="manager-gui"/>
                <role rolename="manager-script"/>
                <user username="tomcat" password="vicky123" roles="manager-gui,manager-script"/>
              </tomcat-users>
              EOXML'

              sudo /opt/tomcat/bin/startup.sh
              echo "Tomcat setup complete." >> /var/log/user-data.log
              EOF

  tags = { Name = "Tomcat-Server" }
}

# ==========================================
# OUTPUTS
# ==========================================
output "Jenkins_Public_IP" {
  value = aws_instance.jenkins.public_ip
}

output "Jenkins_Access_URL" {
  value = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "Jenkins_Password_Command" {
  value = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.jenkins.public_ip} 'cat /var/log/user-data.log | grep -A1 PASSWORD'"
}

output "Tomcat_Public_IP" {
  value = aws_instance.tomcat.public_ip
}

output "Tomcat_Manager_URL" {
  value = "http://${aws_instance.tomcat.public_ip}:8080/manager/html"
}