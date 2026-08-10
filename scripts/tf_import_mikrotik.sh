terraform import module.router.routeros_ip_dhcp_client.dhcp_client "*1"

tf import 'module.access_point_2.routeros_wifi.wifi1[0]' '*4'
tf import 'module.access_point_2.routeros_wifi.wifi2[0]' '*5'

# RouterOS system singletons. Only these three import cleanly; the rest of the /ip and
# /tool menus are adopted by a normal apply, because for a menu that always exists the
# provider's create is a set on the existing object rather than an insert.
#
# Do not add imports for routeros_ip_service, routeros_ip_dns, or
# routeros_ip_neighbor_discovery_settings — see the notes below.

terraform import module.router.routeros_ip_settings.hardening .
terraform import module.router.routeros_tool_mac_server.mac_server .
terraform import module.router.routeros_tool_mac_server_winbox.mac_winbox .

# routeros_ip_service          — import fails ("non-existent remote object") by name and
#                                by numeric id on provider 1.99.1. Apply sets the existing
#                                entry in place and keeps its .id; no duplicate is added.
# routeros_ip_dns              — the provider declares no import support, for the same
#                                reason: its create is a set on a singleton menu.
# routeros_ip_neighbor_discovery_settings
#                              — import fails with "attribute .id not found in the
#                                response"; /ip/neighbor/discovery-settings genuinely
#                                returns no .id. Apply works.
