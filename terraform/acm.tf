resource "aws_acm_certificate" "self_signed" {
  private_key      = file("${path.module}/cert.key")
  certificate_body = file("${path.module}/cert.crt")
}
