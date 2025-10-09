############################################
# Internet/NAT lookups when using existing VPC
############################################
data "aws_internet_gateway" "default" {
  count = var.vpc_id == null ? 0 : 1
  filter {
    name   = "attachment.vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_nat_gateway" "default" {
  count  = var.vpc_id == null ? 0 : 1
  vpc_id = var.vpc_id
}

############################################
# VPC (created when var.vpc_id is null)
############################################
resource "aws_vpc" "this" {
  count                           = var.vpc_id == null ? 1 : 0
  cidr_block                      = var.vpc_cidr
  instance_tenancy                = var.instance_tenancy
  enable_dns_hostnames            = var.enable_dns_hostnames
  enable_dns_support              = var.enable_dns_support
  #enable_classiclink             = var.enable_classiclink
  #enable_classiclink_dns_support = var.enable_classiclink_dns_support
  assign_generated_ipv6_cidr_block = var.enable_ipv6

  tags = merge(
    {
      Name = var.vpc_name != "" ? var.vpc_name : format("%s-%s-VPC", var.environment, var.project_name)
    },
    var.tags
  )
}

############################################
# Internet Gateway (only when creating VPC here)
############################################
resource "aws_internet_gateway" "this" {
  count = var.vpc_id == null && var.create_igw ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(
    { Name = format("%s-%s-IGW", var.environment, var.project_name) },
    var.tags
  )
}

############################################
# Public Route Table + Default Route to IGW
############################################
resource "aws_route_table" "public" {
  count = length(var.public_subnet_cidr) > 0 ? 1 : 0

  vpc_id = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id

  tags = merge(
    { Name = format("%s%s-PublicRouteTable", var.environment, var.project_name) },
    var.tags
  )
}

resource "aws_route" "public_internet_gateway" {
  count = length(var.public_subnet_cidr) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = var.vpc_id == null ? aws_internet_gateway.this[0].id : data.aws_internet_gateway.default[0].internet_gateway_id

  timeouts { create = "5m" }
}

############################################
# Subnets
############################################
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidr) > 0 ? length(var.public_subnet_cidr) : 0

  vpc_id                  = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id
  cidr_block              = var.public_subnet_cidr[count.index]
  availability_zone       = length(regexall("^[a-z]{2}-", element(var.public_azs, count.index))) > 0 ? element(var.public_azs, count.index) : null
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(
    {
      Name = length(var.public_subnet_names) > 0
        ? var.public_subnet_names[count.index]
        : format("%s%s-%s", var.environment, var.project_name, element(var.public_subnet_suffix, count.index))
    },
    var.tags
  )
}

# Application Subnets (Private)
resource "aws_subnet" "app" {
  count = length(var.app_subnet_cidr) > 0 ? length(var.app_subnet_cidr) : 0

  vpc_id            = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id
  cidr_block        = var.app_subnet_cidr[count.index]
  availability_zone = length(regexall("^[a-z]{2}-", element(var.app_azs, count.index))) > 0 ? element(var.app_azs, count.index) : null

  tags = merge(
    {
      Name = length(var.app_subnet_names) > 0
        ? var.app_subnet_names[count.index]
        : format("%s%s-%s", var.environment, var.project_name, element(var.app_subnet_suffix, count.index))
      Tier = "Application"
    },
    var.tags
  )
}

# Data Subnets (Private)
resource "aws_subnet" "data" {
  count = length(var.data_subnet_cidr) > 0 ? length(var.data_subnet_cidr) : 0

  vpc_id            = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id
  cidr_block        = var.data_subnet_cidr[count.index]
  availability_zone = length(regexall("^[a-z]{2}-", element(var.data_azs, count.index))) > 0 ? element(var.data_azs, count.index) : null

  tags = merge(
    {
      Name = length(var.data_subnet_names) > 0
        ? var.data_subnet_names[count.index]
        : format("%s%s-%s", var.environment, var.project_name, element(var.data_subnet_suffix, count.index))
      Tier = "Data"
    },
    var.tags
  )
}

# Legacy Private Subnets (optional/back-compat)
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidr) > 0 ? length(var.private_subnet_cidr) : 0

  vpc_id            = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id
  cidr_block        = var.private_subnet_cidr[count.index]
  availability_zone = length(regexall("^[a-z]{2}-", element(var.private_azs, count.index))) > 0 ? element(var.private_azs, count.index) : null

  tags = merge(
    {
      Name = length(var.private_subnet_names) > 0
        ? var.private_subnet_names[count.index]
        : format("%s%s-%s", var.environment, var.project_name, element(var.private_subnet_suffix, count.index))
    },
    var.tags
  )
}

############################################
# NAT Gateways (count logic)
############################################
locals {
  nat_gateway_count = var.enable_nat_gateway ? (
    var.single_nat_gateway ? 1 : (
      var.one_nat_gateway_per_az ? length(distinct(concat(var.app_azs, var.data_azs, var.private_azs))) : length(var.public_subnet_cidr)
    )
  ) : 0

  has_private_subnets = length(var.app_subnet_cidr) > 0 || length(var.data_subnet_cidr) > 0 || length(var.private_subnet_cidr) > 0
}

resource "aws_eip" "nat" {
  count  = var.vpc_id == null && var.enable_nat_gateway && local.has_private_subnets ? local.nat_gateway_count : 0
  domain = "vpc"

  tags = merge(
    {
      Name = local.nat_gateway_count == 1
        ? format("%s-%s-NGW-EIP", var.environment, var.project_name)
        : format("%s-%s-NGW-EIP-%d", var.environment, var.project_name, count.index + 1)
    },
    var.tags
  )

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.vpc_id == null && var.enable_nat_gateway && local.has_private_subnets ? local.nat_gateway_count : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = element(aws_subnet.public.*.id, count.index)

  tags = merge(
    {
      Name = local.nat_gateway_count == 1
        ? format("%s-%s-NGW", var.environment, var.project_name)
        : format("%s-%s-NGW-%d", var.environment, var.project_name, count.index + 1)
    },
    var.tags
  )

  depends_on = [aws_internet_gateway.this]
}

############################################
# Private Route Tables (App/Data/Private)
############################################
resource "aws_route_table" "app" {
  count = length(var.app_subnet_cidr) > 0 ? (var.single_nat_gateway ? 1 : length(var.app_subnet_cidr)) : 0
  vpc_id = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id

  tags = merge(
    { Name = var.single_nat_gateway ? format("%s%s-AppRouteTable", var.environment, var.project_name) : format("%s%s-AppRouteTable-%d", var.environment, var.project_name, count.index + 1) },
    var.tags
  )
}

resource "aws_route_table" "data" {
  count = length(var.data_subnet_cidr) > 0 ? (var.single_nat_gateway ? 1 : length(var.data_subnet_cidr)) : 0
  vpc_id = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id

  tags = merge(
    { Name = var.single_nat_gateway ? format("%s%s-DataRouteTable", var.environment, var.project_name) : format("%s%s-DataRouteTable-%d", var.environment, var.project_name, count.index + 1) },
    var.tags
  )
}

resource "aws_route_table" "private" {
  count = length(var.private_subnet_cidr) > 0 ? (var.single_nat_gateway ? 1 : length(var.private_subnet_cidr)) : 0
  vpc_id = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id

  tags = merge(
    { Name = var.single_nat_gateway ? format("%s%s-PrivateRouteTable", var.environment, var.project_name) : format("%s%s-PrivateRouteTable-%d", var.environment, var.project_name, count.index + 1) },
    var.tags
  )
}

############################################
# Routes to NAT
############################################
resource "aws_route" "app_nat_gateway" {
  count = var.enable_nat_gateway && length(var.app_subnet_cidr) > 0 ? length(aws_route_table.app) : 0

  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = var.nat_gateway_destination_cidr_block
  nat_gateway_id         = var.vpc_id == null ? element(aws_nat_gateway.this.*.id, var.single_nat_gateway ? 0 : count.index) : data.aws_nat_gateway.default[0].id

  timeouts { create = "5m" }
}

resource "aws_route" "data_nat_gateway" {
  count = var.enable_nat_gateway && length(var.data_subnet_cidr) > 0 ? length(aws_route_table.data) : 0

  route_table_id         = aws_route_table.data[count.index].id
  destination_cidr_block = var.nat_gateway_destination_cidr_block
  nat_gateway_id         = var.vpc_id == null ? element(aws_nat_gateway.this.*.id, var.single_nat_gateway ? 0 : count.index) : data.aws_nat_gateway.default[0].id

  timeouts { create = "5m" }
}

resource "aws_route" "private_nat_gateway" {
  count = var.enable_nat_gateway && length(var.private_subnet_cidr) > 0 ? length(aws_route_table.private) : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = var.nat_gateway_destination_cidr_block
  nat_gateway_id         = var.vpc_id == null ? element(aws_nat_gateway.this.*.id, var.single_nat_gateway ? 0 : count.index) : data.aws_nat_gateway.default[0].id

  timeouts { create = "5m" }
}

############################################
# Route Table Associations
############################################
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidr) > 0 ? length(var.public_subnet_cidr) : 0
  subnet_id      = element(aws_subnet.public.*.id, count.index)
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "app" {
  count          = length(var.app_subnet_cidr) > 0 ? length(var.app_subnet_cidr) : 0
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.app[0].id : aws_route_table.app[count.index].id
}

resource "aws_route_table_association" "data" {
  count          = length(var.data_subnet_cidr) > 0 ? length(var.data_subnet_cidr) : 0
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.data[0].id : aws_route_table.data[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidr) > 0 ? length(var.private_subnet_cidr) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}

############################################
# NACLs (Public/Private)
############################################
resource "aws_network_acl" "public" {
  count     = var.public_dedicated_network_acl && length(var.public_subnet_cidr) > 0 ? 1 : 0
  vpc_id    = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = aws_subnet.public.*.id

  tags = merge({ Name = format("%s%s-PublicNACL", var.environment, var.project_name) }, var.tags)
}

resource "aws_network_acl_rule" "public_inbound" {
  count = var.public_dedicated_network_acl && length(var.public_subnet_cidr) > 0 ? length(var.public_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id
  egress          = false
  rule_number     = var.public_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "public_outbound" {
  count = var.public_dedicated_network_acl && length(var.public_subnet_cidr) > 0 ? length(var.public_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id
  egress          = true
  rule_number     = var.public_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.public_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl" "private" {
  count      = var.private_dedicated_network_acl && length(var.private_subnet_cidr) > 0 ? 1 : 0
  vpc_id     = var.vpc_id == null ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = aws_subnet.private.*.id

  tags = merge({ Name = format("%s%s-PrivateNACL", var.environment, var.project_name) }, var.tags)
}

resource "aws_network_acl_rule" "private_inbound" {
  count = var.private_dedicated_network_acl && length(var.private_subnet_cidr) > 0 ? length(var.private_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id
  egress          = false
  rule_number     = var.private_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "private_outbound" {
  count = var.private_dedicated_network_acl && length(var.private_subnet_cidr) > 0 ? length(var.private_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id
  egress          = true
  rule_number     = var.private_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

############################################
# Transit Gateway (create or use existing)
############################################
resource "aws_ec2_transit_gateway" "this" {
  count = var.create_transit_gateway && var.transit_gateway_id == null ? 1 : 0

  description                      = var.transit_gateway_description
  default_route_table_association  = var.default_route_table_association
  default_route_table_propagation  = var.default_route_table_propagation
  dns_support                      = var.enable_dns_support_tgw ? "enable" : "disable"
  multicast_support                = var.enable_multicast_support_tgw ? "enable" : "disable"
  amazon_side_asn                  = var.amazon_side_asn
  auto_accept_shared_attachments   = var.auto_accept_shared_attachments

  tags = merge({ Name = format("%s%s-TGW", var.environment, var.project_name) }, var.tags)
}

data "aws_ec2_transit_gateway" "existing" {
  count = var.transit_gateway_id != null ? 1 : 0
  id    = var.transit_gateway_id
}

############################################
# TGW VPC Attachment (simple & correct)
############################################
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.create_tgw_vpc_attachment && (var.create_transit_gateway || var.transit_gateway_id != null) ? 1 : 0

  vpc_id             = var.vpc_id != null ? var.vpc_id : aws_vpc.this[0].id
  transit_gateway_id = var.transit_gateway_id != null ? var.transit_gateway_id : aws_ec2_transit_gateway.this[0].id

  # ✅ Use ONE subnet class (ensures only one subnet per AZ). Here: PUBLIC.
  # If you prefer private/app, change to: [for s in aws_subnet.app : s.id]
  subnet_ids = [for s in aws_subnet.public : s.id]

  dns_support                                 = var.enable_dns_support_tgw ? "enable" : "disable"
  transit_gateway_default_route_table_association = var.default_route_table_association == "enable"
  transit_gateway_default_route_table_propagation = var.default_route_table_propagation == "enable"

  tags = merge(
    { Name = format("%s-%s-TGW-Attachment", var.environment, var.project_name) },
    var.tags
  )
}
