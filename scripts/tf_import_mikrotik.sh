terraform import module.router.routeros_ip_dhcp_client.dhcp_client "*1"

tf import 'module.access_point_2.routeros_wifi.wifi1[0]' '*4'
tf import 'module.access_point_2.routeros_wifi.wifi2[0]' '*5'

########################################################################
# Adopted drift (2026-07-06). RouterOS resources import by internal id
# (*X). `find` alone returns bare ids in an ambiguous order, so use these
# id->key mapping commands and substitute the *XX placeholders below.
# NOTE: sprinkleract_config is inline (no separate channel/security object).
#
#   Router (10.69.100.1) -- BGP already filled in; leases need mapping:
#     :foreach i in=[/ip/dhcp-server/lease find where dynamic=no] \
#       do={:put ($i . "  " . [/ip/dhcp-server/lease get $i address])}
#   AP1 (10.69.100.20):
#     :foreach i in=[/interface/wifi find] \
#       do={:put ($i . "  " . [/interface/wifi get $i name])}
#     :foreach i in=[/interface/wifi/configuration find] \
#       do={:put ($i . "  " . [/interface/wifi/configuration get $i name])}
#     :foreach i in=[/interface/bridge/port find where interface=wifi3] do={:put $i}
########################################################################

# --- Router: BGP peers ---
tf import 'module.router.routeros_routing_bgp_connection.peer["Makima-1 Peer"]' '*1'
tf import 'module.router.routeros_routing_bgp_connection.peer["Makima-2 Peer"]' '*2'
tf import 'module.router.routeros_routing_bgp_connection.peer["Makima-3 Peer"]' '*3'

# --- Router: static DHCP leases ---
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["makima-1"]'   '*173'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["makima-2"]'   '*174'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["makima-3"]'   '*176'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["trusted-21"]' '*177'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["trusted-22"]' '*178'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["trusted-23"]' '*179'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["trusted-30"]' '*6'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["mgmt-30"]'    '*30'
tf import 'module.router.routeros_ip_dhcp_server_lease.lease["mgmt-32"]'    '*180'

# --- AP1: SprinklerAct wifi config (inline, single object) + virtual AP ---
tf import 'routeros_wifi_configuration.sprinkleract'                                      '*4'
tf import 'module.access_point_1.routeros_wifi.virtual_ap["wifi3"]'                       '*E'
tf import 'module.access_point_1.routeros_interface_bridge_port.virtual_ap_port["wifi3"]' '*9'

# --- AP1: manager radio -> strudel_config binding ---
tf import 'module.access_point_1.routeros_wifi.wifi1_manager[0]' '*4'
tf import 'module.access_point_1.routeros_wifi.wifi2_manager[0]' '*5'
