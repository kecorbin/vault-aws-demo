output "vault-ip" {
    value = "${aws_instance.vault-server.public_ip}"
}

output "vault-login" {
    value = "ssh -i ~/keys/${var.key_pair}.pem ubuntu@${aws_instance.vault-server.public_ip}"
}

output "mysql-host" {
    value = "${aws_db_instance.vault-mysql.endpoint}"
}

output "ec2-allow-instance" {
    value = "ssh -i ~/keys/${var.key_pair}.pem ubuntu@${aws_instance.vault-ec2-allow.public_ip}"
}

output "ec2-deny-instance" {
    value = "ssh -i ~/keys/${var.key_pair}.pem ubuntu@${aws_instance.vault-ec2-deny.public_ip}"
}
