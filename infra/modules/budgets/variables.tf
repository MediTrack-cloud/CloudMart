variable "environment" {
  type = string
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "monthly_budget_usd" {
  type    = string
  default = "50"
}
