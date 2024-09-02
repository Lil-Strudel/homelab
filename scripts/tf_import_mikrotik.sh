terraform import module.router.routeros_ip_dhcp_client.dhcp_client "*1"

tf import 'module.access_point_2.routeros_wifi.wifi1[0]' '*4'
tf import 'module.access_point_2.routeros_wifi.wifi2[0]' '*5'
