output "waf_arn" { value = aws_wafv2_web_acl.main.arn }
output "waf_id"  { value = aws_wafv2_web_acl.main.id }
output "guardduty_detector_id" { value = length(aws_guardduty_detector.main) > 0 ? aws_guardduty_detector.main[0].id : "" }
output "guardduty_sns_arn"     { value = aws_sns_topic.guardduty_findings.arn }
