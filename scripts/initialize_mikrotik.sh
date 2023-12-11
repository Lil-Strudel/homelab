/ip dhcp-client add disabled=no interface=ether1 
/certificate add name=root-cert common-name=root-cert key-size=4096 days-valid=3650 key-usage=key-cert-sign,crl-sign
/certificate add name=tls-cert common-name=tls-cert key-size=4096 days-valid=3650 key-usage=digital-signature,key-agreement,tls-server

/certificate sign root-cert

/certificate sign tls-cert ca=root-cert

/ip service enable www-ssl
/ip service set www-ssl certificate=tls-cert port=6729
