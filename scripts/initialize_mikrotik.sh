/interface bridge add name=temp_bridge
/interface bridge port add interface=ether3 bridge=temp_bridge

/ip address add address=10.69.200.1/24 interface=temp_bridge 
/ip pool add name=temp_dhcp_pool ranges=10.69.200.2-10.69.200.254 
/ip dhcp-server add name=temp_dhcp_server interface=temp_bridge lease-time=10m address-pool=temp_dhcp_pool 
/ip dhcp-server network add address=10.69.200.0/24 gateway=10.69.200.1 dns-server=9.9.9.9 
/ip dhcp-client add disabled=no interface=ether1 
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade 
/certificate add name=root-cert common-name=root-cert key-size=4096 days-valid=3650 key-usage=key-cert-sign,crl-sign
/certificate add name=tls-cert common-name=tls-cert key-size=4096 days-valid=3650 key-usage=digital-signature,key-agreement,tls-server

/certificate sign root-cert

/certificate sign tls-cert ca=root-cert

/ip service enable www-ssl
/ip service set www-ssl certificate=tls-cert port=6729
/ip service set winbox port=9712
/user add name=strudel password=1234 group=full
/user add name=terraform password=1234 group=full

/user remove admin
