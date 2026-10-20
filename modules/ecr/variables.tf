variable "repositories" {
  description = "Image names, e.g. [\"getpack/api\", \"getpack/web\"]"
  type        = list(string)
}

variable "keep_sha_images" {
  type    = number
  default = 15
}
