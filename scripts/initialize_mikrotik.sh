/interface bridge add name=local
/interface bridge port add interface=ether2 bridge=local

/ip address add address=10.69.100.1/24 interface=local
/ip pool add name=mgmt_dhcp_pool ranges=10.69.100.2-10.69.100.254
/ip dhcp-server add name=mgmt_dhcp_server interface=local lease-time=10m address-pool=mgmt_dhcp_pool 
/ip dhcp-server network add address=10.69.100.0/24 gateway=10.69.100.1 dns-server=8.8.8.8
/ip dhcp-client add disabled=no interface=ether1
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
/certificate add name=root-cert common-name=root-cert key-size=4096 days-valid=3650 key-usage=key-cert-sign,crl-sign
/certificate add name=tls-cert common-name=tls-cert key-size=4096 days-valid=3650 key-usage=digital-signature,key-agreement,tls-server

/certificate sign root-cert

/certificate sign tls-cert ca=root-cert

/ip service enable www-ssl
/ip service set www-ssl certificate=tls-cert port=6729
/ip service set winbox port=9712
/user add name=strudel password=12345 group=full
/user add name=terraform password=12345 group=full

/user remove admin
