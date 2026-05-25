variable "environment" { type = string }

variable "ses_from_email" {
  description = "Verified sender email address for SES (set to empty string to skip)"
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Alert email to receive GuardDuty SNS findings"
  type        = string
  default     = ""
}

variable "enable_guardduty" {
  description = "Create a GuardDuty detector. Requires a paid/subscribed account."
  type        = bool
  default     = false
}
