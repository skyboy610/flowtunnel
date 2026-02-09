#!/bin/bash

# FlowTunnel - Anti-DPI TCP Tunnel Manager
# Connection rotation & session breaking for VPN traffic

PYTHON_BIN="/usr/bin/python3"
HAPROXY_BIN="/usr/sbin/haproxy"
TUNNEL_DAEMON="/usr/local/bin/flowtunnel-daemon"
TUNNEL_DB="/root/.flowtunnel.json"
SYSTEMD_PATH="/etc/systemd/system"

declare -A COLORS=(
    [RESET]='\033[0m'
    [RED]='\033[38;5;196m'
    [GREEN]='\033[38;5;46m'
    [PINK]='\033[38;5;213m'
    [CYAN]='\033[38;5;51m'
    [YELLOW]='\033[38;5;226m'
    [ORANGE]='\033[38;5;208m'
    [BLUE]='\033[38;5;33m'
    [OLIVE]='\033[38;5;142m'
    [PURPLE]='\033[38;5;93m'
    [MAGENTA]='\033[38;5;201m'
)

print_color() {
    local color="$1"
    local text="$2"
    echo -e "${COLORS[$color]}${text}${COLORS[RESET]}"
}

clear_screen() {
    printf "\033c"
}

print_logo() {
    echo ""
    echo -e "${COLORS[CYAN]}  ███████╗${COLORS[PINK]}██╗      ${COLORS[YELLOW]}██████╗ ${COLORS[ORANGE]}██╗    ██╗${COLORS[RESET]}"
    echo -e "${COLORS[CYAN]}  ██╔════╝${COLORS[PINK]}██║     ${COLORS[YELLOW]}██╔═══██╗${COLORS[ORANGE]}██║    ██║${COLORS[RESET]}"
    echo -e "${COLORS[CYAN]}  █████╗  ${COLORS[PINK]}██║     ${COLORS[YELLOW]}██║   ██║${COLORS[ORANGE]}██║ █╗ ██║${COLORS[RESET]}"
    echo -e "${COLORS[CYAN]}  ██╔══╝  ${COLORS[PINK]}██║     ${COLORS[YELLOW]}██║   ██║${COLORS[ORANGE]}██║███╗██║${COLORS[RESET]}"
    echo -e "${COLORS[CYAN]}  ██║     ${COLORS[PINK]}███████╗${COLORS[YELLOW]}╚██████╔╝${COLORS[ORANGE]}╚███╔███╔╝${COLORS[RESET]}"
    echo -e "${COLORS[CYAN]}  ╚═╝     ${COLORS[PINK]}╚══════╝${COLORS[YELLOW]} ╚═════╝ ${COLORS[ORANGE]} ╚══╝╚══╝ ${COLORS[RESET]}"
    echo ""
    print_color "MAGENTA" "  A N T I - D P I   T U N N E L   M A N A G E R"
    print_color "ORANGE" "  ═══════════════════════════════════════════════════"
    echo ""
    
    if [[ -f "$HAPROXY_BIN" ]] && [[ -f "$TUNNEL_DAEMON" ]]; then
        print_color "GREEN" "  ✓ FlowTunnel Installed"
    else
        print_color "RED" "  ✗ FlowTunnel Not Installed"
    fi
    echo ""
}

print_header() {
    clear_screen
    print_logo
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_color "RED" "✗ This script must be run as root"
        exit 1
    fi
}

press_enter() {
    echo ""
    print_color "ORANGE" "Press Enter to continue..."
    read -r
}

init_tunnel_db() {
    if [[ ! -f "$TUNNEL_DB" ]]; then
        echo "{}" > "$TUNNEL_DB"
    fi
}

save_tunnel_info() {
    local name="$1"
    local service_name="$2"
    local listen_port="$3"
    local backend_ip="$4"
    local backend_port="$5"
    local rotation_interval="$6"
    
    init_tunnel_db
    
    local temp_file=$(mktemp)
    jq --arg name "$name" \
       --arg service "$service_name" \
       --arg lport "$listen_port" \
       --arg bip "$backend_ip" \
       --arg bport "$backend_port" \
       --arg rotation "$rotation_interval" \
       '.[$service] = {name: $name, listen_port: $lport, backend_ip: $bip, backend_port: $bport, rotation: $rotation}' \
       "$TUNNEL_DB" > "$temp_file" 2>/dev/null || echo "{}" > "$temp_file"
    
    mv "$temp_file" "$TUNNEL_DB"
}

get_tunnel_info() {
    local service_name="$1"
    init_tunnel_db
    jq -r --arg service "$service_name" '.[$service] // empty' "$TUNNEL_DB" 2>/dev/null
}

delete_tunnel_info() {
    local service_name="$1"
    init_tunnel_db
    
    local temp_file=$(mktemp)
    jq --arg service "$service_name" 'del(.[$service])' "$TUNNEL_DB" > "$temp_file" 2>/dev/null
    mv "$temp_file" "$TUNNEL_DB"
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

check_port_in_use() {
    local port="$1"
    if ss -tuln | grep -q ":${port} "; then
        return 0
    fi
    return 1
}

list_tunnels() {
    local tunnels=()
    for service in ${SYSTEMD_PATH}/flowtunnel-*.service; do
        if [[ -f "$service" ]]; then
            local name=$(basename "$service" .service)
            tunnels+=("$name")
        fi
    done
    echo "${tunnels[@]}"
}

create_rotation_daemon() {
    cat > "$TUNNEL_DAEMON" << 'DAEMON_EOF'
#!/usr/bin/env python3
"""
FlowTunnel Connection Rotation Daemon
Prevents DPI detection by rotating connections
"""

import socket
import select
import threading
import time
import random
import sys
import signal
import os

class ConnectionRotator:
    def __init__(self, listen_port, backend_host, backend_port, rotation_interval=30):
        self.listen_port = listen_port
        self.backend_host = backend_host
        self.backend_port = backend_port
        self.rotation_interval = rotation_interval
        self.running = True
        self.active_connections = {}
        
    def add_jitter(self, data):
        """Add random padding to break traffic patterns"""
        if len(data) < 1400:  # Don't pad full MTU packets
            padding_size = random.randint(0, 50)
            padding = os.urandom(padding_size)
            # Simple XOR obfuscation
            key = random.randint(1, 255)
            obfuscated = bytes([b ^ key for b in data])
            return bytes([key]) + obfuscated + padding
        return data
    
    def remove_jitter(self, data):
        """Remove padding and deobfuscate"""
        if len(data) < 2:
            return data
        try:
            key = data[0]
            # Remove padding (last random bytes)
            payload = data[1:-random.randint(0, 50)] if len(data) > 100 else data[1:]
            deobfuscated = bytes([b ^ key for b in payload])
            return deobfuscated
        except:
            return data
    
    def handle_client(self, client_sock, client_addr):
        """Handle individual client with connection rotation"""
        conn_id = f"{client_addr[0]}:{client_addr[1]}"
        print(f"[+] New connection: {conn_id}")
        
        backend_sock = None
        last_rotation = time.time()
        
        try:
            client_sock.setblocking(0)
            
            while self.running:
                current_time = time.time()
                
                # Rotate backend connection periodically
                if backend_sock is None or (current_time - last_rotation) > self.rotation_interval:
                    if backend_sock:
                        print(f"[~] Rotating connection: {conn_id}")
                        backend_sock.close()
                    
                    # Create new backend connection
                    backend_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    backend_sock.settimeout(10)
                    
                    try:
                        backend_sock.connect((self.backend_host, self.backend_port))
                        backend_sock.setblocking(0)
                        last_rotation = current_time
                        print(f"[+] Backend connected: {conn_id}")
                    except Exception as e:
                        print(f"[-] Backend connection failed: {e}")
                        time.sleep(1)
                        continue
                
                # Select for reading
                readable, _, exceptional = select.select(
                    [client_sock, backend_sock], [], [client_sock, backend_sock], 1
                )
                
                if exceptional:
                    break
                
                for sock in readable:
                    try:
                        data = sock.recv(8192)
                        if not data:
                            return
                        
                        if sock is client_sock:
                            # Client -> Backend
                            backend_sock.sendall(data)
                        else:
                            # Backend -> Client
                            client_sock.sendall(data)
                    
                    except BlockingIOError:
                        continue
                    except Exception as e:
                        print(f"[-] Transfer error: {e}")
                        return
        
        except Exception as e:
            print(f"[-] Connection error {conn_id}: {e}")
        
        finally:
            print(f"[-] Closed connection: {conn_id}")
            if backend_sock:
                backend_sock.close()
            client_sock.close()
            if conn_id in self.active_connections:
                del self.active_connections[conn_id]
    
    def start(self):
        """Start listening server"""
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('0.0.0.0', self.listen_port))
        server.listen(100)
        
        print(f"[*] FlowTunnel listening on 0.0.0.0:{self.listen_port}")
        print(f"[*] Backend: {self.backend_host}:{self.backend_port}")
        print(f"[*] Rotation interval: {self.rotation_interval}s")
        
        def signal_handler(sig, frame):
            print("\n[!] Shutting down...")
            self.running = False
            server.close()
            sys.exit(0)
        
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
        
        try:
            while self.running:
                try:
                    client_sock, client_addr = server.accept()
                    thread = threading.Thread(
                        target=self.handle_client,
                        args=(client_sock, client_addr),
                        daemon=True
                    )
                    thread.start()
                except Exception as e:
                    if self.running:
                        print(f"[-] Accept error: {e}")
                        time.sleep(0.1)
        
        finally:
            server.close()

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: flowtunnel-daemon <listen_port> <backend_ip> <backend_port> <rotation_interval>")
        sys.exit(1)
    
    listen_port = int(sys.argv[1])
    backend_host = sys.argv[2]
    backend_port = int(sys.argv[3])
    rotation_interval = int(sys.argv[4])
    
    rotator = ConnectionRotator(listen_port, backend_host, backend_port, rotation_interval)
    rotator.start()
DAEMON_EOF

    chmod +x "$TUNNEL_DAEMON"
}

install_flowtunnel() {
    clear_screen
    print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN" "  Installing FlowTunnel"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""
    
    if [[ -f "$TUNNEL_DAEMON" ]] && [[ -f "$HAPROXY_BIN" ]]; then
        print_color "YELLOW" "⚠ FlowTunnel is already installed"
        print_color "BLUE" "Do you want to reinstall? (yes/no)"
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            return
        fi
    fi
    
    clear_screen
    print_logo
    print_color "PINK" "→ Installing dependencies..."
    
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y python3 haproxy jq net-tools >/dev/null 2>&1
    
    clear_screen
    print_logo
    print_color "CYAN" "→ Creating rotation daemon..."
    
    create_rotation_daemon
    
    # Enable IP forwarding
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null
    sysctl -p >/dev/null 2>&1
    
    # Optimize TCP for tunneling
    cat >> /etc/sysctl.conf << 'EOF'

# FlowTunnel optimizations
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_timestamps=1
EOF
    
    sysctl -p >/dev/null 2>&1
    
    clear_screen
    print_logo
    print_color "GREEN" "✓ FlowTunnel installed successfully"
    press_enter
}

add_tunnel_iran() {
    clear_screen
    print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN" "  Add Iran Tunnel (Proxy Server)"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""
    
    print_color "PINK" "Tunnel name:"
    read -r tunnel_name
    
    if [[ -z "$tunnel_name" ]]; then
        print_color "RED" "✗ Tunnel name is required"
        sleep 2
        return
    fi
    
    while true; do
        echo ""
        print_color "YELLOW" "Listen Port (VPN clients will connect here):"
        read -r listen_port
        
        if ! validate_port "$listen_port"; then
            print_color "RED" "✗ Invalid port"
            sleep 1
            continue
        fi
        
        if check_port_in_use "$listen_port"; then
            print_color "RED" "✗ Port $listen_port is already in use"
            sleep 1
            continue
        fi
        break
    done
    
    echo ""
    print_color "CYAN" "Backend IP (Kharej server IP):"
    read -r backend_ip
    
    if ! validate_ip "$backend_ip"; then
        print_color "RED" "✗ Invalid IP address"
        sleep 2
        return
    fi
    
    echo ""
    print_color "ORANGE" "Backend Port (Port on Kharej server):"
    read -r backend_port
    
    if ! validate_port "$backend_port"; then
        print_color "RED" "✗ Invalid port"
        sleep 2
        return
    fi
    
    echo ""
    print_color "BLUE" "Connection Rotation Interval (seconds, recommended: 20-60):"
    read -r rotation_interval
    
    if [[ ! "$rotation_interval" =~ ^[0-9]+$ ]] || [[ "$rotation_interval" -lt 10 ]]; then
        rotation_interval=30
        print_color "YELLOW" "Using default: 30 seconds"
        sleep 1
    fi
    
    local service_name="flowtunnel-iran-${listen_port}"
    
    # Create systemd service
    cat > "${SYSTEMD_PATH}/${service_name}.service" << EOF
[Unit]
Description=FlowTunnel Iran Proxy - ${tunnel_name}
After=network.target

[Service]
Type=simple
ExecStart=$TUNNEL_DAEMON $listen_port $backend_ip $backend_port $rotation_interval
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "${service_name}.service" >/dev/null 2>&1
    systemctl start "${service_name}.service"
    
    save_tunnel_info "$tunnel_name" "$service_name" "$listen_port" "$backend_ip" "$backend_port" "$rotation_interval"
    
    clear_screen
    print_logo
    
    if systemctl is-active --quiet "${service_name}.service"; then
        print_color "GREEN" "✓ Iran tunnel created successfully"
        echo ""
        print_color "CYAN" "  Name: ${tunnel_name}"
        print_color "PINK" "  Listen Port: ${listen_port}"
        print_color "YELLOW" "  Backend: ${backend_ip}:${backend_port}"
        print_color "BLUE" "  Rotation: ${rotation_interval}s"
        echo ""
        print_color "MAGENTA" "  Configure your VPN to connect to:"
        print_color "MAGENTA" "  → Server: $(hostname -I | awk '{print $1}')"
        print_color "MAGENTA" "  → Port: ${listen_port}"
    else
        print_color "RED" "✗ Failed to start tunnel"
    fi
    
    press_enter
}

add_tunnel_kharej() {
    clear_screen
    print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN" "  Add Kharej Tunnel (Backend Server)"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""
    
    print_color "PINK" "Tunnel name:"
    read -r tunnel_name
    
    if [[ -z "$tunnel_name" ]]; then
        print_color "RED" "✗ Tunnel name is required"
        sleep 2
        return
    fi
    
    while true; do
        echo ""
        print_color "YELLOW" "Listen Port (Iran will forward here):"
        read -r listen_port
        
        if ! validate_port "$listen_port"; then
            print_color "RED" "✗ Invalid port"
            sleep 1
            continue
        fi
        
        if check_port_in_use "$listen_port"; then
            print_color "RED" "✗ Port $listen_port is already in use"
            sleep 1
            continue
        fi
        break
    done
    
    echo ""
    print_color "CYAN" "VPN Server IP (localhost or actual VPN IP):"
    read -r vpn_ip
    
    if [[ -z "$vpn_ip" ]]; then
        vpn_ip="127.0.0.1"
    fi
    
    echo ""
    print_color "ORANGE" "VPN Server Port:"
    read -r vpn_port
    
    if ! validate_port "$vpn_port"; then
        print_color "RED" "✗ Invalid port"
        sleep 2
        return
    fi
    
    local service_name="flowtunnel-kharej-${listen_port}"
    
    # Use simple socat for kharej side (no rotation needed)
    cat > "${SYSTEMD_PATH}/${service_name}.service" << EOF
[Unit]
Description=FlowTunnel Kharej Backend - ${tunnel_name}
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:${listen_port},fork,reuseaddr TCP4:${vpn_ip}:${vpn_port}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    
    # Install socat if not present
    if ! command -v socat &> /dev/null; then
        apt-get install -y socat >/dev/null 2>&1
    fi
    
    systemctl daemon-reload
    systemctl enable "${service_name}.service" >/dev/null 2>&1
    systemctl start "${service_name}.service"
    
    save_tunnel_info "$tunnel_name" "$service_name" "$listen_port" "$vpn_ip" "$vpn_port" "0"
    
    clear_screen
    print_logo
    
    if systemctl is-active --quiet "${service_name}.service"; then
        print_color "GREEN" "✓ Kharej tunnel created successfully"
        echo ""
        print_color "CYAN" "  Name: ${tunnel_name}"
        print_color "PINK" "  Listen Port: ${listen_port}"
        print_color "YELLOW" "  VPN Backend: ${vpn_ip}:${vpn_port}"
        echo ""
        print_color "MAGENTA" "  Use this in Iran tunnel configuration:"
        print_color "MAGENTA" "  → Backend IP: $(hostname -I | awk '{print $1}')"
        print_color "MAGENTA" "  → Backend Port: ${listen_port}"
    else
        print_color "RED" "✗ Failed to start tunnel"
    fi
    
    press_enter
}

add_tunnel_menu() {
    while true; do
        clear_screen
        print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN" "  Add Tunnel"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""
        print_color "PINK" "[1] Iran Server (Proxy with Anti-DPI)"
        print_color "CYAN" "[2] Kharej Server (VPN Backend)"
        print_color "OLIVE" "[0] Back"
        echo ""
        print_color "YELLOW" "Select option:"
        read -r choice
        
        case $choice in
            1) add_tunnel_iran ;;
            2) add_tunnel_kharej ;;
            0) return ;;
            *)
                clear_screen
                print_logo
                print_color "RED" "✗ Invalid option"
                sleep 1
                ;;
        esac
    done
}

manage_tunnel_menu() {
    while true; do
        clear_screen
        print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN" "  Manage Tunnels"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""
        
        local tunnels=($(list_tunnels))
        if [[ ${#tunnels[@]} -eq 0 ]]; then
            print_color "RED" "✗ No tunnels found"
            press_enter
            return
        fi
        
        local i=1
        for tunnel in "${tunnels[@]}"; do
            local info=$(get_tunnel_info "$tunnel")
            local name=$(echo "$info" | jq -r '.name // "Unknown"' 2>/dev/null)
            local port=$(echo "$info" | jq -r '.listen_port // "N/A"' 2>/dev/null)
            
            if systemctl is-active --quiet "$tunnel"; then
                print_color "GREEN" "[$i] $name | Port: $port (Active)"
            else
                print_color "RED" "[$i] $name | Port: $port (Inactive)"
            fi
            ((i++))
        done
        
        print_color "OLIVE" "[0] Back"
        echo ""
        print_color "YELLOW" "Select tunnel:"
        read -r choice
        
        if [[ "$choice" == "0" ]]; then
            return
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#tunnels[@]} ]]; then
            local selected_tunnel="${tunnels[$((choice-1))]}"
            manage_tunnel_actions "$selected_tunnel"
        fi
    done
}

manage_tunnel_actions() {
    local tunnel="$1"
    
    while true; do
        clear_screen
        print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN" "  Manage: $tunnel"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""
        print_color "PINK" "[1] Start"
        print_color "CYAN" "[2] Stop"
        print_color "YELLOW" "[3] Restart"
        print_color "ORANGE" "[4] View Logs"
        print_color "BLUE" "[5] Delete"
        print_color "OLIVE" "[0] Back"
        echo ""
        print_color "PINK" "Select action:"
        read -r action
        
        case $action in
            1)
                systemctl start "$tunnel"
                clear_screen
                print_logo
                if systemctl is-active --quiet "$tunnel"; then
                    print_color "GREEN" "✓ Tunnel started"
                else
                    print_color "RED" "✗ Failed to start"
                fi
                sleep 2
                ;;
            2)
                systemctl stop "$tunnel"
                clear_screen
                print_logo
                print_color "GREEN" "✓ Tunnel stopped"
                sleep 2
                ;;
            3)
                systemctl restart "$tunnel"
                clear_screen
                print_logo
                if systemctl is-active --quiet "$tunnel"; then
                    print_color "GREEN" "✓ Tunnel restarted"
                else
                    print_color "RED" "✗ Failed to restart"
                fi
                sleep 2
                ;;
            4)
                clear_screen
                print_color "CYAN" "═══════════════════════════════════════════════════"
                print_color "YELLOW" "  Logs: $tunnel (Last 30 lines)"
                print_color "CYAN" "═══════════════════════════════════════════════════"
                echo ""
                journalctl -u "$tunnel" -n 30 --no-pager 2>/dev/null
                press_enter
                ;;
            5)
                clear_screen
                print_logo
                print_color "RED" "⚠ Delete $tunnel? (yes/no)"
                read -r confirm
                
                if [[ "$confirm" == "yes" ]]; then
                    systemctl stop "$tunnel" 2>/dev/null
                    systemctl disable "$tunnel" 2>/dev/null
                    rm -f "${SYSTEMD_PATH}/${tunnel}.service"
                    delete_tunnel_info "$tunnel"
                    systemctl daemon-reload
                    
                    print_color "GREEN" "✓ Tunnel deleted"
                    sleep 2
                    return
                fi
                ;;
            0) return ;;
        esac
    done
}

show_status() {
    clear_screen
    print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN" "  Tunnel Status"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""
    
    local tunnels=($(list_tunnels))
    if [[ ${#tunnels[@]} -eq 0 ]]; then
        print_color "RED" "✗ No tunnels found"
    else
        for tunnel in "${tunnels[@]}"; do
            local info=$(get_tunnel_info "$tunnel")
            local name=$(echo "$info" | jq -r '.name // "Unknown"' 2>/dev/null)
            local port=$(echo "$info" | jq -r '.listen_port // "N/A"' 2>/dev/null)
            local rotation=$(echo "$info" | jq -r '.rotation // "N/A"' 2>/dev/null)
            
            if systemctl is-active --quiet "$tunnel"; then
                print_color "GREEN" "✓ $name | Port: $port | Rotation: ${rotation}s"
            else
                print_color "RED" "✗ $name | Port: $port | Rotation: ${rotation}s"
            fi
        done
    fi
    
    press_enter
}

uninstall_flowtunnel() {
    clear_screen
    print_logo
    print_color "RED" "⚠ This will remove ALL tunnels and FlowTunnel"
    print_color "YELLOW" "Continue? (yes/no)"
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        return
    fi
    
    local tunnels=($(list_tunnels))
    for tunnel in "${tunnels[@]}"; do
        systemctl stop "$tunnel" 2>/dev/null
        systemctl disable "$tunnel" 2>/dev/null
        rm -f "${SYSTEMD_PATH}/${tunnel}.service"
    done
    
    rm -f "$TUNNEL_DAEMON"
    rm -f "$TUNNEL_DB"
    
    systemctl daemon-reload
    
    clear_screen
    print_logo
    print_color "GREEN" "✓ FlowTunnel uninstalled"
    press_enter
}

main_menu() {
    if ! command -v jq &> /dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y jq >/dev/null 2>&1
    fi
    
    init_tunnel_db
    
    while true; do
        clear_screen
        print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN" "  Main Menu"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""
        print_color "PINK" "[1] Install FlowTunnel"
        print_color "CYAN" "[2] Add Tunnel"
        print_color "YELLOW" "[3] Manage Tunnels"
        print_color "ORANGE" "[4] Tunnel Status"
        print_color "BLUE" "[5] Uninstall"
        print_color "RED" "[6] Exit"
        echo ""
        print_color "CYAN" "Select option:"
        read -r choice
        
        case $choice in
            1) install_flowtunnel ;;
            2)
                if [[ ! -f "$TUNNEL_DAEMON" ]]; then
                    clear_screen
                    print_logo
                    print_color "RED" "✗ Please install FlowTunnel first"
                    sleep 2
                else
                    add_tunnel_menu
                fi
                ;;
            3)
                if [[ ! -f "$TUNNEL_DAEMON" ]]; then
                    clear_screen
                    print_logo
                    print_color "RED" "✗ Please install FlowTunnel first"
                    sleep 2
                else
                    manage_tunnel_menu
                fi
                ;;
            4) show_status ;;
            5) uninstall_flowtunnel ;;
            6)
                clear_screen
                print_color "CYAN" "Thank you for using FlowTunnel!"
                echo ""
                exit 0
                ;;
        esac
    done
}

check_root
main_menu
