terraform {
  # 1.11 floor to match the estate. The module itself only needs terraform_data (built in): the
  # bastion, its public IP and the sign-in role are created and deleted with az by the scripts, so
  # they are never in state and one apply can both create and delete them.
  required_version = ">= 1.11.0, < 2.0.0"
}
