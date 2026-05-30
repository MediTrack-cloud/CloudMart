data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Velero backup bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "velero" {
  bucket        = "cloudmart-velero-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "cloudmart-velero" }
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DR static error page bucket (Route 53 failover target)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "dr_static" {
  bucket        = "cloudmart-dr-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "cloudmart-dr-static-${var.environment}" }
}

resource "aws_s3_bucket_website_configuration" "dr_static" {
  bucket = aws_s3_bucket.dr_static.id
  index_document { suffix = "index.html" }
  error_document { key = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "dr_static" {
  bucket                  = aws_s3_bucket.dr_static.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "dr_static" {
  bucket     = aws_s3_bucket.dr_static.id
  depends_on = [aws_s3_bucket_public_access_block.dr_static]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dr_static.arn}/*"
    }]
  })
}

resource "aws_s3_object" "error_page" {
  bucket       = aws_s3_bucket.dr_static.id
  key          = "index.html"
  content_type = "text/html"
  content      = <<-HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>CloudMart — Maintenance</title>
      <style>
        body { font-family: -apple-system, sans-serif; display: flex; align-items: center;
               justify-content: center; min-height: 100vh; margin: 0;
               background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; }
        .card { text-align: center; padding: 2rem; max-width: 500px; }
        h1 { font-size: 2rem; margin-bottom: 1rem; }
        p  { opacity: 0.9; line-height: 1.6; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>CloudMart</h1>
        <h2>We'll be back soon</h2>
        <p>CloudMart is currently undergoing scheduled maintenance.
           We apologise for the inconvenience and expect to be back online shortly.</p>
        <p>If you have an urgent query, please contact support.</p>
      </div>
    </body>
    </html>
  HTML
}
