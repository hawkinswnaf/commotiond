#!/bin/sh

. /lib/functions.sh
. /lib/functions/commotion.sh
. /lib/config/uci.sh
. ../netifd-proto.sh
init_proto "$@"

DEFAULT_CLIENT_BRIDGE="lan"
DEFAULT_CLIENT_SUBNET="10.0.0.0"
DEFAULT_CLIENT_NETMASK="255.255.255.0"
DEFAULT_CLIENT_IPGENMASK="255.0.0.0"
WIFI_DEVICE=
TYPE=

configure_wifi_iface() {
	local config="$1"
	local network="$2"
	local ssid=
	local mode=
	local wpakey=
	local wpa=
	local thisnetwork=
	config_get thisnetwork "$config" network	
	[[ "$thisnetwork" == "$network" ]] && {
		config_get ssid "$config" ssid "$(commotion_get_ssid $iface)"
		uci_set wireless "$config" ssid "$ssid"
		config_get mode "$config" mode "$(commotion_get_mode $iface)"
		uci_set wireless "$config" mode "$mode"
		config_get encryption "$config" encryption "$(commotion_get_encryption $iface)"
		if [ -n "$encryption" -a "$encryption" != "none" ]; then 
			uci_set wireless "$config" encryption "$encryption"
			config_get key "$config" key "$(commotion_get_key $iface)"
			uci_set wireless "$config" key "$key"
		else
			uci_set wireless "$config" encryption "none"
		fi
		config_get WIFI_DEVICE "$config" device
	}
}

configure_wifi_device() {
	local config="$1"
	local thisradio="$2"	
	local channel="$3"
	
	[[ "$config" == "$thisradio" ]] && {
		config_set "$config" channel "$channel"
	}
}

proto_commotion_init_config() {
	proto_config_add_string "profile"
	proto_config_add_string "type"
	proto_config_add_string "class"
	proto_config_add_string "ipaddr"
	proto_config_add_string "netmask"
	proto_config_add_string "dns"
	proto_config_add_string "domain"
}

proto_commotion_setup() {
	local config="$1"
	local iface="$2"
	local have_ip=0
	local dhcp=
	local client_bridge="$(uci_get network "$config" client_bridge "$DEFAULT_CLIENT_BRIDGE")"
	
	local profile type ipaddr netmask dns domain announce lease_zone nolease_zone
	json_get_vars profile type class ipaddr netmask dns domain announce lease_zone nolease_zone

	logger -s -t commotion.proto "Running protocol handler."
	[ "$class" == "mesh" ] && commotion_up "$iface" $(uci_get network $config profile)
	case "$class" in
 	"mesh")
		logger -t "commotion.proto" -s "Class: $class"
		commotion_up "$iface" $(uci_get network $config profile)
		logger -t "commotion.proto" -s "Upped $iface"
		uci_set_state network "$config" meshed "$(uci_get network "$config" meshed 1)"
		uci_set_state network "$config" announced "$(uci_get network "$config" announced 0)"
      	;;
	"client")
		logger -t "commotion.proto" -s "Class: $class"
		uci_set_state network "$config" meshed "$(uci_get network "$config" meshed 0)"
		uci_set_state network "$config" announced "$(uci_get network "$config" announced 1)"
      	;;
	"wired")
		logger -t "commotion.proto" -s "Class: $class"
		uci_set_state network "$config" meshed "$(uci_get network "$config" meshed 0)"
		uci_set_state network "$config" announced "$(uci_get network "$config" announced 0)"
		dhcp="$(uci_get network "$config" dhcp "auto")"
      		uci_set_state network "$config" dhcp "$dhcp"
      
      case "$dhcp" in
        "auto")
	      	local dhcp_status
	      	local dhcp_timeout="$(uci_get commotiond @node[0] dhcp_timeout "$DHCP_TIMEOUT")"
	      	
	      	unset_bridge "$client_bridge" "$iface"
	      	logger -t "commotion.proto" -s "Removing $iface from bridge $client_bridge"
	      	export DHCP_INTERFACE="$config"
	      	udhcpc -q -i ${iface} -t 2 -T "$dhcp_timeout" -n -s /lib/netifd/commotion.dhcp.script
	      	dhcp_status=$?
	      	export DHCP_INTERFACE=""
	      	if [ $dhcp_status -eq 0 ]; then
	      		# we got an IP
	      		# see commotion.dhcp.script for the rest of
	      		# the setup code.
	      		have_ip=1
	      		uci_set_state network "$config" lease 2

	      		# get out of here early.
	      		return
	      	else
	      		unset_fwzone "$config"
	      		uci_commit firewall
	      		uci_set_state network "$config" lease 1
	      		set_bridge "$client_bridge" "$iface"
	      		logger -t "commotion.proto" -s "Adding $iface to bridge $client_bridge"
	      		
	      		logger -t "commotion.proto" -s "Restarting $client_bridge interface"
	      		ubus call network.interface."$client_bridge" down
	      		ubus call network.interface."$client_bridge" up
	      		local bridge_ip="$(uci_get_state network $client_bridge ipaddr $(commotion_gen_ip $DEFAULT_CLIENT_SUBNET $DEFAULT_CLIENT_IPGENMASK gw))"
	      		logger -t "commotion.proto" -s "Bridge IP state: $(uci_get_state $client_bridge ipaddr)"
	      		logger -t "commotion.proto" -s "Bridge generated IP: $(commotion_gen_ip $DEFAULT_CLIENT_SUBNET $DEFAULT_CLIENT_IPGENMASK gw)"
	      		local bridge_netmask="$(uci_get_state network $client_bridge netmask $DEFAULT_CLIENT_NETMASK)"
	      		logger -t "commotion.proto" -s "Bridge Netmask state: $(uci_get_state $client_bridge netmask)"
	      		logger -t "commotion.proto" -s "Bridge Default netmask: $DEFAULT_CLIENT_NETMASK"
	      		logger -t "commotion.proto" -s "Bridge: $client_bridge, IP: $bridge_ip, Netmask: $bridge_netmask"
	      		uci_set network "$client_bridge" ipaddr "$bridge_ip"
	      		uci_set_state network "$client_bridge" ipaddr "$bridge_ip"
	      		uci_set network "$client_bridge" netmask "$bridge_netmask"
	      		uci_set_state network "$client_bridge" netmask "$bridge_netmask"
	      		logger -t "commotion.proto" -s "Restarting dnsmasq"
	      		sleep 1
	      		/etc/init.d/dnsmasq restart
	      					
	      		return
	      	fi
        ;;
        "server")
	      	unset_fwzone "$config"
	      	uci_commit firewall
	      	uci_set_state network "$config" lease 1
	      	set_bridge "$client_bridge" "$iface"
	      	logger -t "commotion.proto" -s "Adding $iface to bridge $client_bridge"
	      	
	      	logger -t "commotion.proto" -s "Restarting $client_bridge interface"
	      	ubus call network.interface."$client_bridge" down
	      	ubus call network.interface."$client_bridge" up
	      	local bridge_ip="$(uci_get_state $client_bridge ipaddr $(commotion_gen_ip $DEFAULT_CLIENT_SUBNET $DEFAULT_CLIENT_IPGENMASK gw))"
	      	local bridge_netmask="$(uci_get_state $client_bridge netmask $DEFAULT_CLIENT_SUBNET)"
	      	logger -t "commotion.proto" -s "Bridge: $client_bridge, IP: $bridge_ip, Netmask: $bridge_netmask"
	      	uci_set network "$client_bridge" ipaddr "$bridge_ip"
	      	uci_set network "$client_bridge" netmask "$bridge_netmask"
	      	logger -t "commotion.proto" -s "Restarting dnsmasq"
	      	/etc/init.d/dnsmasq restart
	      				
	      	return
        ;;
        "client")
	      	local dhcp_status
	      	local dhcp_timeout="$(uci_get commotiond @node[0] dhcp_timeout "$DHCP_TIMEOUT")"
	      	
	      	unset_bridge "$client_bridge" "$iface"
	      	logger -t "commotion.proto" -s "Removing $iface from bridge $client_bridge"
	      	export DHCP_INTERFACE="$config"
	      	proto_run_command "$config" udhcpc -i ${iface} -t 2 -T "$dhcp_timeout" -n -s /lib/netifd/commotion.dhcp.script
        ;;
      esac
      ;;
  esac

	proto_init_update "*" 1
	
	if [ $have_ip -eq 0 ]; then
		if [ "$class" != "mesh" ]; then
			local ip=${ipaddr:-$(commotion_gen_ip $DEFAULT_CLIENT_SUBNET $DEFAULT_CLIENT_IPGENMASK gw)} 
			local netmask=${netmask:-$DEFAULT_CLIENT_NETMASK}
			proto_add_ipv4_address $ip $netmask
			logger -t "commotion.proto" -s "proto_add_ipv4_address: $ip $netmask"
			uci_set_state network "$config" ipaddr "$ip"
			uci_set_state network "$config" netmask "$netmask"
		else
			local ip=${ipaddr:-$(commotion_get_ip $iface)}
			local netmask=${netmask:-$(commotion_get_netmask $iface)}
			proto_add_ipv4_address $ip $netmask
			uci_set_state network "$config" ipaddr "$ip"
			uci_set_state network "$config" netmask "$netmask"           
			logger -t "commotion.proto" -s "proto_add_ipv4_address: $ip $netmask"
			proto_add_dns_server "${dns:-$(commotion_get_dns $iface)}"   
			logger -t "commotion.proto" -s "proto_add_dns_server: $dns"
			proto_add_dns_search ${domain:-$(commotion_get_domain $iface)}          
			logger -t "commotion.proto" -s "proto_add_dns_search: $domain"
    		fi
	fi

	proto_export "INTERFACE=$config"
	proto_export "TYPE=$type"
	proto_export "MODE=${mode:-$(commotion_get_mode $iface)}"
	proto_export "ANNOUNCE=${announce:-$(commotion_get_announce $iface)}"

	if [ "$class" == "mesh" ]; then
		config_load wireless
		config_foreach configure_wifi_iface wifi-iface $config
		local channel=$(uci_get wireless "$WIFI_DEVICE" channel)
		uci_set wireless $WIFI_DEVICE channel ${channel:-$(commotion_get_channel $iface)}
    		uci_commit wireless
    		wifi up "$config"
	fi
	logger -t "commotion.proto" -s "Sending update for $config"
	proto_send_update "$config"
}

proto_commotion_teardown() {
	local config="$1"
	local ifname="$2"
		
	logger -t "commotion.proto" -s "Initiating teardown."
	
	local class = "$(uci_get network "$config" class)"
	
	if [ "$class" == "wired" ]; then
	    local client_bridge="$(uci_get network "$config" client_bridge "$DEFAULT_CLIENT_BRIDGE")"
	    unset_bridge "$client_bridge" "$ifname"
	    logger -t "commotion.proto" -s "Removing $ifname from bridge $client_bridge"
	
	    proto_kill_command "$config"
	fi
}	

add_protocol commotion

