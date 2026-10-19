output "public_ip" {
  description = "Public IPv4 address of the SkyBook VM."
  value       = oci_core_instance.skybook.public_ip
}

output "ssh_command" {
  description = "SSH into the VM."
  value       = "ssh -i ${trimsuffix(var.ssh_public_key_path, ".pub")} ubuntu@${oci_core_instance.skybook.public_ip}"
}

output "next_steps" {
  description = "What to do after terraform apply."
  value       = <<-EOT
    The Ansible inventory is at infra/ansible/inventory/hosts.ini. Next:
      cd ../ansible
      cp group_vars/all/vault.example.yml group_vars/all/vault.yml   # first time only: fill it in
      ansible-vault encrypt group_vars/all/vault.yml                  # first time only
      ansible-playbook site.yml --ask-vault-pass
      export KUBECONFIG=~/.kube/skybook.yaml && kubectl get nodes
  EOT
}
