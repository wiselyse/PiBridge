#!/bin/bash

# Function to check for root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root (or with sudo)."
        exit 1
    fi
}

# Function to check and install necessary packages
install_required_packages() {
    echo "Checking for required packages..."

    # Array of required packages
    REQUIRED_PACKAGES=("hostapd" "dnsmasq" "iptables" "wpa_supplicant")

    # Loop through the packages and check if they are installed
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s $pkg > /dev/null 2>&1; then
            echo "Installing $pkg..."
            sudo apt-get install -y $pkg
        else
            echo "$pkg is already installed."
        fi
    done

    echo "All required packages are installed."
}

# Function to check if wlan0 and wlan1 interfaces exist
check_interfaces() {
    if ! ip link show wlan0 > /dev/null 2>&1; then
        echo "Error: wlan0 interface not found. Please ensure it is available."
        exit 1
    fi

    if ! ip link show wlan1 > /dev/null 2>&1; then
        echo "Error: wlan1 interface not found. Please ensure it is available."
        exit 1
    fi

    echo "wlan0 and wlan1 interfaces are both available."
}

# Function to check for internet connectivity
check_internet() {
    if ping -c 4 8.8.8.8 > /dev/null 2>&1; then
        echo "Internet connection is available."
        return 0
    else
        echo "No internet connection detected."
        return 1
    fi
}

# Function for initial Wi-Fi setup if no internet is detected
initial_wifi_setup() {
    echo "Performing initial Wi-Fi setup..."

    # Prompt for Wi-Fi credentials
    read -p "Enter Wi-Fi SSID: " WIFI_SSID
    read -sp "Enter Wi-Fi Password: " WIFI_PASSWORD
    echo ""

    # Update wpa_supplicant.conf for wlan1 to connect to Wi-Fi
    sudo bash -c "cat > /etc/wpa_supplicant/wpa_supplicant-wlan1.conf <<EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASSWORD\"
}
EOF"
    
    # Restart network services
    sudo wpa_supplicant -B -i wlan1 -c /etc/wpa_supplicant/wpa_supplicant-wlan1.conf
    sudo systemctl restart dhcpcd

    # Wait for connection
    sleep 5
    if check_internet; then
        echo "Wi-Fi connected successfully."
    else
        echo "Failed to connect to Wi-Fi. Please check your credentials and try again."
        initial_wifi_setup
    fi
}

# Function to set up AP and client Wi-Fi mode
setup_ap_client_mode() {
    echo "Setting up Wi-Fi access point on wlan0 and client on wlan1..."

    # Update the wpa_supplicant.conf with client Wi-Fi details
    sudo bash -c "cat > /etc/wpa_supplicant/wpa_supplicant-wlan1.conf <<EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASSWORD\"
}
EOF"

    echo "Updated wlan1 Wi-Fi configuration."

    # Set up wlan0 as an access point
    sudo bash -c "cat > /etc/dnsmasq.conf <<EOF
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
EOF"

    sudo bash -c "cat > /etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF"

    sudo systemctl restart hostapd dnsmasq
    echo "Access point configuration complete."

    # Enable routing and NAT for wlan0 to wlan1
    sudo iptables -t nat -A POSTROUTING -o wlan1 -j MASQUERADE
    sudo iptables-save | sudo tee /etc/iptables.ipv4.nat > /dev/null

    sudo systemctl restart dhcpcd
    echo "Routing and NAT configuration applied."

    # Connect wlan1 to Wi-Fi network
    sudo wpa_supplicant -B -i wlan1 -c /etc/wpa_supplicant/wpa_supplicant-wlan1.conf
    echo "Connecting wlan1 to Wi-Fi..."

    sleep 5  # Give time for wlan1 to connect

    if check_internet; then
        echo "Successfully connected to Wi-Fi on wlan1."
    else
        echo "Failed to connect to Wi-Fi on wlan1. Keeping AP active so you can try again."
    fi

    # Show network information
    show_network_info
}

# Function to reconfigure the AP (SSID and password)
reconfigure_ap() {
    read -p "Enter new SSID for Access Point: " AP_SSID
    read -sp "Enter new Password for Access Point: " AP_PASSWORD
    echo ""

    # Update hostapd configuration
    sudo bash -c "cat > /etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF"

    sudo systemctl restart hostapd
    echo "Access Point SSID and password reconfigured."
}

# Function to reconfigure the Wi-Fi connection (SSID and password)
reconfigure_wifi() {
    read -p "Enter new SSID for Wi-Fi: " WIFI_SSID
    read -sp "Enter new Password for Wi-Fi: " WIFI_PASSWORD
    echo ""

    # Update wpa_supplicant configuration
    sudo bash -c "cat > /etc/wpa_supplicant/wpa_supplicant-wlan1.conf <<EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid=\"$WIFI_SSID\"
    psk=\"$WIFI_PASSWORD\"
}
EOF"

    sudo systemctl restart dhcpcd
    echo "Wi-Fi SSID and password reconfigured."
}

# Function to revert back to the original state (no AP, just client Wi-Fi)
revert_original_state() {
    echo "Reverting back to original state..."

    # Stop hostapd and dnsmasq services
    sudo systemctl stop hostapd dnsmasq

    # Remove NAT rule
    sudo iptables -t nat -D POSTROUTING -o wlan1 -j MASQUERADE
    sudo iptables-save | sudo tee /etc/iptables.ipv4.nat > /dev/null

    # Remove static IP from wlan0
    sudo sed -i '/interface wlan0/d' /etc/dhcpcd.conf

    # Reconnect to Wi-Fi using wlan0
    sudo systemctl restart dhcpcd
    echo "Restoring wlan0 to Wi-Fi client mode..."

    # Show network information
    show_network_info
}

# Function to display network status and IP addresses
show_network_info() {
    # Show wlan0 and wlan1 IP addresses
    IP_WLAN0=$(hostname -I | awk '{print $1}')
    IP_WLAN1=$(ip -o -4 addr show wlan1 | awk '{print $4}' | cut -d/ -f1)
    
    echo "wlan0 (AP) IP Address: $IP_WLAN0"
    echo "wlan1 (Client) IP Address: $IP_WLAN1"

    # Check if internet is available on wlan1
    if check_internet; then
        echo "Internet connection on wlan1: Available"
    else
        echo "Internet connection on wlan1: Unavailable"
    fi
}

# Function to display current SSIDs for AP and Wi-Fi
show_current_ssids() {
    # Get the current SSID of the Access Point (AP)
    AP_SSID=$(grep -oP '(?<=^ssid=).*' /etc/hostapd/hostapd.conf)
    
    # Get the current SSID of the Wi-Fi connection
    WIFI_SSID=$(grep -oP '(?<=^ssid=").*?(?=")' /etc/wpa_supplicant/wpa_supplicant-wlan1.conf)
    
    echo "Current Access Point SSID: $AP_SSID"
    echo "Current Wi-Fi SSID: $WIFI_SSID"
}

# Main script logic
main() {
    echo "Wi-Fi AP and Client Mode Switcher"

    # Check for root privileges
    check_root

    # Update and install necessary packages
    sudo apt-get update
    install_required_packages

    # Check if wlan0 and wlan1 interfaces are available
    check_interfaces

    # Check for internet connectivity, prompt for initial Wi-Fi setup if needed
    if ! check_internet; then
        initial_wifi_setup
    fi

    # Prompt for action
    echo "What would you like to do?"
    echo "1. Setup AP on wlan0 and connect wlan1 to Wi-Fi"
    echo "2. Revert back to original state"
    echo "3. Reconfigure AP SSID and password"
    echo "4. Reconfigure Wi-Fi SSID and password"
    echo "5. Show current SSIDs for AP and Wi-Fi"
    read -p "Enter choice (1, 2, 3, 4, or 5): " CHOICE

    if [ "$CHOICE" -eq 1 ]; then
        # Ask for network details
        read -p "Enter Wi-Fi SSID for wlan1: " WIFI_SSID
        read -sp "Enter Wi-Fi Password for wlan1: " WIFI_PASSWORD
        echo ""
        read -p "Enter SSID for the access point (wlan0): " AP_SSID
        read -sp "Enter Password for the access point (wlan0): " AP_PASSWORD
        echo ""

        # Set up AP and client mode
        setup_ap_client_mode
    elif [ "$CHOICE" -eq 2 ]; then
        # Revert to original state
        revert_original_state
    elif [ "$CHOICE" -eq 3 ]; then
        # Reconfigure AP SSID and password
        reconfigure_ap
    elif [ "$CHOICE" -eq 4 ]; then
        # Reconfigure Wi-Fi SSID and password
        reconfigure_wifi
    elif [ "$CHOICE" -eq 5 ]; then
        # Show current SSIDs for AP and Wi-Fi
        show_current_ssids
    else
        echo "Invalid choice. Exiting."
        exit 1
    fi
}

# Execute the main function
main