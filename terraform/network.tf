# VPC, subnets, single fck-nat instance (no NAT Gateway) and GuardDuty destroy-time cleanup.

resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:Flow logs not needed for a demo
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })

  depends_on = [terraform_data.account_guard]
}

# Default SG: no rules (CKV2_AWS_12)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name}-default-locked" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

# Subnets depend on the GuardDuty cleanup so that, on destroy, cleanup runs after everything
# inside the subnets (EKS, nodes, fck-nat) is gone and before subnets/VPC are deleted.
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = false # tfsec/CKV_AWS_130: instances get EIPs explicitly
  tags = merge(local.tags, {
    Name                     = "${local.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })

  depends_on = [null_resource.vpc_guardduty_cleanup]
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  tags = merge(local.tags, {
    Name                              = "${local.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })

  depends_on = [null_resource.vpc_guardduty_cleanup]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name}-private" })
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# fck-nat: single t4g.nano ARM64 instance in the first public subnet.
data "aws_ami" "fck_nat" {
  most_recent = true
  owners      = ["568608671756"] # fck-nat project
  filter {
    name   = "name"
    values = ["fck-nat-al2023-hvm-*-arm64-ebs"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_security_group" "fck_nat" {
  name_prefix = "${local.name}-fck-nat-"
  description = "fck-nat: allow all traffic from the VPC, egress anywhere"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-fck-nat" })

  ingress {
    description = "All traffic from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Internet egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] #checkov:skip=CKV_AWS_382:NAT instance must reach the internet on all ports
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "fck_nat" {
  #checkov:skip=CKV_AWS_88:NAT instance requires a public IP to provide egress
  #checkov:skip=CKV2_AWS_41:fck-nat needs no IAM role
  ami                         = data.aws_ami.fck_nat.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.fck_nat.id]
  source_dest_check           = false
  associate_public_ip_address = true
  monitoring                  = true
  ebs_optimized               = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = merge(local.tags, { Name = "${local.name}-fck-nat" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.fck_nat.primary_network_interface_id
}

# GuardDuty Runtime Monitoring creates VPC endpoints, ENIs and a managed security group inside
# the VPC that Terraform does not track and that block VPC deletion. This destroy-time
# provisioner removes them: endpoints, then ENIs (poll up to 3 min), then non-default SGs
# (retry every 30s up to 5 min). SG deletion errors are never swallowed.
#
# Destroy ordering: subnets depend on this resource, so EKS, nodes and fck-nat (which live in
# the subnets) are destroyed first, then this runs, then subnets and VPC are deleted.
resource "null_resource" "vpc_guardduty_cleanup" {
  triggers = {
    vpc_id  = aws_vpc.main.id
    region  = var.region
    profile = "company"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      VPC_ID      = self.triggers.vpc_id
      AWS_REGION  = self.triggers.region
      AWS_PROFILE = self.triggers.profile
      AWS_PAGER   = ""
    }
    command = <<-EOT
      set -uo pipefail
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

      echo "== GuardDuty cleanup for $VPC_ID =="

      # 1. VPC endpoints
      EPS=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID \
        --query 'VpcEndpoints[].VpcEndpointId' --output text)
      if [ -n "$EPS" ]; then
        echo "Deleting VPC endpoints: $EPS"
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EPS >/dev/null || exit 1
        for i in $(seq 1 18); do
          LEFT=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID \
            --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text)
          [ -z "$LEFT" ] && break
          sleep 10
        done
      fi

      # 2. ENIs: wait up to 3 min for instance ENIs to drain, delete what remains
      for i in $(seq 1 18); do
        ENIS=$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC_ID \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
        [ -z "$ENIS" ] && break
        for eni in $ENIS; do
          STATUS=$(aws ec2 describe-network-interfaces --network-interface-ids $eni \
            --query 'NetworkInterfaces[0].Status' --output text 2>/dev/null || echo gone)
          if [ "$STATUS" = "available" ]; then
            echo "Deleting ENI $eni"
            aws ec2 delete-network-interface --network-interface-id $eni 2>/dev/null || true
          fi
        done
        sleep 10
      done

      # 3. Non-default SGs: retry every 30s for up to 5 min, fail if any remain
      for i in $(seq 1 10); do
        SGS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
          --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
        [ -z "$SGS" ] && { echo "No non-default SGs remain"; exit 0; }
        FAILED=0
        for sg in $SGS; do
          echo "Deleting SG $sg (attempt $i)"
          aws ec2 delete-security-group --group-id $sg || FAILED=1
        done
        [ "$FAILED" = "0" ] && continue
        sleep 30
      done

      SGS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
      if [ -n "$SGS" ]; then
        echo "ERROR: could not delete security groups: $SGS" >&2
        exit 1
      fi
    EOT
  }
}
