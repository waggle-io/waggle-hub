# ──────────────────────────────────────────────────────────
# AWS Private CA + exportable ACM Certificate (wildcard)
# ──────────────────────────────────────────────────────────

resource "aws_acmpca_certificate_authority" "this" {
  type = "ROOT"

  certificate_authority_configuration {
    key_algorithm     = "RSA_2048"
    signing_algorithm = "SHA256WITHRSA"

    subject {
      common_name  = var.domain_name
      organization = var.organization_name
    }
  }

  permanent_deletion_time_in_days = 7

  tags = merge(var.tags, {
    Name = "${var.organization_name}-private-ca"
  })
}

# Self-signed root cert to activate the CA
resource "aws_acmpca_certificate" "root" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.this.arn
  certificate_signing_request = aws_acmpca_certificate_authority.this.certificate_signing_request
  signing_algorithm           = "SHA256WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = 10
  }
}

resource "aws_acmpca_certificate_authority_certificate" "this" {
  certificate_authority_arn = aws_acmpca_certificate_authority.this.arn
  certificate               = aws_acmpca_certificate.root.certificate
}

# Exportable wildcard cert issued by the Private CA
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = ["flightctl.${var.domain_name}", "*.flightctl.${var.domain_name}"]
  certificate_authority_arn = aws_acmpca_certificate_authority.this.arn

  depends_on = [aws_acmpca_certificate_authority_certificate.this]

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-cert"
  })
}
