output "dr_bucket_name" { value = aws_s3_bucket.dr_static.bucket }
output "dr_website_endpoint" { value = aws_s3_bucket_website_configuration.dr_static.website_endpoint }
