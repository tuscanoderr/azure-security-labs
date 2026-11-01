variable "location" {
  type    = string
  default = "eastus"
}

variable "prefix" {
  type    = string
  default = "genai-irf"
}

variable "model_name" {
  type    = string
  default = "gpt-5-mini"
}

variable "model_version" {
  type    = string
  default = "2025-08-07"
}

# Generated tokens in 15 minutes on one account that the A6 analytics rule treats as a token flood
variable "token_threshold" {
  type    = number
  default = 15000
}
