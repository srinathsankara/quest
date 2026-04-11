variable "region" {
  default = "us-east-2"
}

variable "secret_word" {
  description = "SECRET_WORD from the index page"
}

variable "image" {
  default = "charlesragen/quest:latest"
}
