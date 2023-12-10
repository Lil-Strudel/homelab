terraform import routeros_interface_bridge.bridge bridge
terraform import routeros_interface_bridge_port.bridge_port "*0"
terraform import routeros_ip_address.address "*1" 
terraform import routeros_ip_pool.mgmt_pool mgmt_dhcp_pool
terraform import routeros_ip_dhcp_server.dhcp_server mgmt_dhcp_server
terraform import routeros_ip_dhcp_server_network.dhcp_server_network "*1"
terraform import routeros_ip_dhcp_client.dhcp_client "*1"
terraform import routeros_ip_firewall_nat.nat_rule "*1" 
terraform import routeros_system_certificate.root_cert "*1"
terraform import routeros_system_certificate.tls_cert "*2"
terraform import routeros_system_user.strudel_user "*2"
terraform import routeros_system_user.terraform_user "*3"
