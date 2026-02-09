#!/bin/bash

# FlowTunnel Test & Verification Script

COLORS_RED='\033[0;31m'
COLORS_GREEN='\033[0;32m'
COLORS_YELLOW='\033[1;33m'
COLORS_BLUE='\033[0;34m'
COLORS_CYAN='\033[0;36m'
COLORS_NC='\033[0m' # No Color

print_header() {
    clear
    echo -e "${COLORS_CYAN}╔════════════════════════════════════════════════════╗${COLORS_NC}"
    echo -e "${COLORS_CYAN}║   FlowTunnel Test & Verification Tool            ║${COLORS_NC}"
    echo -e "${COLORS_CYAN}╚════════════════════════════════════════════════════╝${COLORS_NC}"
    echo ""
}

test_port() {
    local host=$1
    local port=$2
    local timeout=5
    
    if timeout $timeout bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

test_connectivity() {
    local host=$1
    local port=$2
    
    echo -e "${COLORS_YELLOW}[TEST]${COLORS_NC} Testing connectivity to $host:$port..."
    
    if test_port "$host" "$port"; then
        echo -e "${COLORS_GREEN}[PASS]${COLORS_NC} Port $port is reachable\n"
        return 0
    else
        echo -e "${COLORS_RED}[FAIL]${COLORS_NC} Port $port is NOT reachable\n"
        return 1
    fi
}

test_tunnel_service() {
    local service_name=$1
    
    echo -e "${COLORS_YELLOW}[TEST]${COLORS_NC} Checking service: $service_name..."
    
    if systemctl is-active --quiet "$service_name"; then
        echo -e "${COLORS_GREEN}[PASS]${COLORS_NC} Service is active\n"
        return 0
    else
        echo -e "${COLORS_RED}[FAIL]${COLORS_NC} Service is NOT active\n"
        systemctl status "$service_name" --no-pager -n 5
        return 1
    fi
}

test_rotation() {
    local host=$1
    local port=$2
    local duration=90
    
    echo -e "${COLORS_YELLOW}[TEST]${COLORS_NC} Testing connection rotation ($duration seconds)..."
    echo -e "${COLORS_CYAN}       This will monitor connection count changes${COLORS_NC}\n"
    
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local rotation_detected=0
    
    local initial_conn_count=$(ss -tn state established "( sport = :$port )" 2>/dev/null | grep -c "ESTAB" || echo "0")
    echo -e "       Initial connections: $initial_conn_count"
    
    while [ $(date +%s) -lt $end_time ]; do
        sleep 10
        local current_conn_count=$(ss -tn state established "( sport = :$port )" 2>/dev/null | grep -c "ESTAB" || echo "0")
        
        if [ "$current_conn_count" != "$initial_conn_count" ]; then
            rotation_detected=1
            echo -e "       Connection count changed: $initial_conn_count -> $current_conn_count"
            initial_conn_count=$current_conn_count
        fi
        
        echo -n "."
    done
    
    echo ""
    
    if [ $rotation_detected -eq 1 ]; then
        echo -e "${COLORS_GREEN}[PASS]${COLORS_NC} Connection rotation detected\n"
        return 0
    else
        echo -e "${COLORS_YELLOW}[WARN]${COLORS_NC} No rotation detected (may need more traffic)\n"
        return 1
    fi
}

test_throughput() {
    local host=$1
    local port=$2
    
    echo -e "${COLORS_YELLOW}[TEST]${COLORS_NC} Testing throughput..."
    
    # Create 10MB test file
    local test_file="/tmp/flowtunnel_test_$(date +%s).bin"
    dd if=/dev/urandom of="$test_file" bs=1M count=10 2>/dev/null
    
    echo -e "${COLORS_CYAN}       Sending 10MB test data...${COLORS_NC}"
    
    local start_time=$(date +%s.%N)
    
    if nc -w 5 "$host" "$port" < "$test_file" >/dev/null 2>&1; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        local speed=$(echo "scale=2; 10 / $duration" | bc)
        
        echo -e "${COLORS_GREEN}[PASS]${COLORS_NC} Throughput: ${speed} MB/s\n"
        rm -f "$test_file"
        return 0
    else
        echo -e "${COLORS_RED}[FAIL]${COLORS_NC} Throughput test failed\n"
        rm -f "$test_file"
        return 1
    fi
}

run_basic_tests() {
    print_header
    
    echo -e "${COLORS_BLUE}Basic Tests${COLORS_NC}"
    echo -e "${COLORS_BLUE}═══════════${COLORS_NC}\n"
    
    # Test dependencies
    echo -e "${COLORS_YELLOW}[TEST]${COLORS_NC} Checking dependencies..."
    local deps_ok=1
    
    for cmd in systemctl ss nc jq python3; do
        if command -v $cmd &> /dev/null; then
            echo -e "       ✓ $cmd"
        else
            echo -e "       ✗ $cmd ${COLORS_RED}NOT FOUND${COLORS_NC}"
            deps_ok=0
        fi
    done
    
    if [ $deps_ok -eq 1 ]; then
        echo -e "${COLORS_GREEN}[PASS]${COLORS_NC} All dependencies present\n"
    else
        echo -e "${COLORS_RED}[FAIL]${COLORS_NC} Missing dependencies\n"
        return 1
    fi
    
    # Test FlowTunnel installation
    echo -e "${COLORS_YELLOW}[TEST]${COLORS_NC} Checking FlowTunnel installation..."
    
    if [ -f /usr/local/bin/flowtunnel-daemon ]; then
        echo -e "${COLORS_GREEN}[PASS]${COLORS_NC} FlowTunnel daemon found\n"
    else
        echo -e "${COLORS_RED}[FAIL]${COLORS_NC} FlowTunnel daemon not found\n"
        return 1
    fi
    
    # List active tunnels
    echo -e "${COLORS_YELLOW}[TEST]${COLORS_NC} Checking active tunnels..."
    
    local tunnel_count=$(systemctl list-units --type=service --state=running | grep -c "flowtunnel-" || echo "0")
    
    if [ $tunnel_count -gt 0 ]; then
        echo -e "${COLORS_GREEN}[PASS]${COLORS_NC} Found $tunnel_count active tunnel(s)\n"
        systemctl list-units --type=service --state=running | grep "flowtunnel-" | awk '{print "       - "$1}'
        echo ""
    else
        echo -e "${COLORS_YELLOW}[WARN]${COLORS_NC} No active tunnels found\n"
    fi
}

run_tunnel_test() {
    print_header
    
    echo -e "${COLORS_BLUE}Tunnel Test${COLORS_NC}"
    echo -e "${COLORS_BLUE}═══════════${COLORS_NC}\n"
    
    # List available tunnels
    echo "Available tunnels:"
    local i=1
    declare -a tunnels
    
    for service in /etc/systemd/system/flowtunnel-*.service; do
        if [ -f "$service" ]; then
            local name=$(basename "$service" .service)
            tunnels[$i]="$name"
            echo "[$i] $name"
            ((i++))
        fi
    done
    
    if [ ${#tunnels[@]} -eq 0 ]; then
        echo -e "${COLORS_RED}No tunnels found${COLORS_NC}"
        return 1
    fi
    
    echo ""
    echo -n "Select tunnel to test (1-${#tunnels[@]}): "
    read selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#tunnels[@]} ]; then
        echo -e "${COLORS_RED}Invalid selection${COLORS_NC}"
        return 1
    fi
    
    local selected_tunnel="${tunnels[$selection]}"
    
    print_header
    echo -e "${COLORS_BLUE}Testing: $selected_tunnel${COLORS_NC}\n"
    
    # Test service status
    test_tunnel_service "$selected_tunnel"
    
    # Get tunnel info
    local tunnel_info=$(jq -r --arg service "$selected_tunnel" '.[$service] // empty' /root/.flowtunnel.json 2>/dev/null)
    
    if [ -z "$tunnel_info" ]; then
        echo -e "${COLORS_YELLOW}[WARN]${COLORS_NC} Could not load tunnel configuration\n"
        return 1
    fi
    
    local listen_port=$(echo "$tunnel_info" | jq -r '.listen_port // "N/A"')
    local backend_ip=$(echo "$tunnel_info" | jq -r '.backend_ip // "N/A"')
    local backend_port=$(echo "$tunnel_info" | jq -r '.backend_port // "N/A"')
    
    echo "Configuration:"
    echo "  Listen Port: $listen_port"
    echo "  Backend: $backend_ip:$backend_port"
    echo ""
    
    # Test local port
    test_connectivity "127.0.0.1" "$listen_port"
    
    # Test backend (if not localhost)
    if [ "$backend_ip" != "127.0.0.1" ] && [ "$backend_ip" != "N/A" ]; then
        test_connectivity "$backend_ip" "$backend_port"
    fi
    
    echo -e "${COLORS_CYAN}Additional Tests:${COLORS_NC}"
    echo "  [1] Test connection rotation"
    echo "  [2] View live logs"
    echo "  [3] Skip"
    echo ""
    echo -n "Select test: "
    read test_choice
    
    case $test_choice in
        1)
            test_rotation "127.0.0.1" "$listen_port"
            ;;
        2)
            echo -e "\n${COLORS_CYAN}Press Ctrl+C to exit logs${COLORS_NC}\n"
            sleep 2
            journalctl -u "$selected_tunnel" -f
            ;;
    esac
}

show_menu() {
    print_header
    
    echo -e "${COLORS_BLUE}Test Menu${COLORS_NC}"
    echo -e "${COLORS_BLUE}═════════${COLORS_NC}\n"
    echo "  [1] Run basic system tests"
    echo "  [2] Test specific tunnel"
    echo "  [3] Monitor all tunnels"
    echo "  [4] Network diagnostics"
    echo "  [0] Exit"
    echo ""
    echo -n "Select option: "
}

monitor_tunnels() {
    print_header
    
    echo -e "${COLORS_BLUE}Tunnel Monitor${COLORS_NC}"
    echo -e "${COLORS_BLUE}══════════════${COLORS_NC}\n"
    
    echo "Monitoring all FlowTunnel services (Ctrl+C to exit)..."
    echo ""
    
    while true; do
        clear
        print_header
        
        echo -e "${COLORS_BLUE}Active Tunnels${COLORS_NC} ($(date '+%Y-%m-%d %H:%M:%S'))\n"
        
        for service in /etc/systemd/system/flowtunnel-*.service; do
            if [ -f "$service" ]; then
                local name=$(basename "$service" .service)
                
                if systemctl is-active --quiet "$name"; then
                    local info=$(jq -r --arg service "$name" '.[$service] // empty' /root/.flowtunnel.json 2>/dev/null)
                    local port=$(echo "$info" | jq -r '.listen_port // "N/A"')
                    local conn_count=$(ss -tn state established "( sport = :$port )" 2>/dev/null | grep -c "ESTAB" || echo "0")
                    
                    echo -e "${COLORS_GREEN}● $name${COLORS_NC}"
                    echo "  Port: $port | Connections: $conn_count"
                else
                    echo -e "${COLORS_RED}● $name${COLORS_NC} (inactive)"
                fi
                echo ""
            fi
        done
        
        sleep 5
    done
}

network_diagnostics() {
    print_header
    
    echo -e "${COLORS_BLUE}Network Diagnostics${COLORS_NC}"
    echo -e "${COLORS_BLUE}═══════════════════${COLORS_NC}\n"
    
    echo -e "${COLORS_YELLOW}[INFO]${COLORS_NC} Network interfaces:"
    ip addr show | grep -E "^[0-9]+:|inet " | sed 's/^/  /'
    echo ""
    
    echo -e "${COLORS_YELLOW}[INFO]${COLORS_NC} Listening ports (FlowTunnel):"
    ss -tuln | grep -E ":(443|80|8080|8443)" | sed 's/^/  /'
    echo ""
    
    echo -e "${COLORS_YELLOW}[INFO]${COLORS_NC} Active connections:"
    ss -tn state established | grep -c "ESTAB" | xargs echo "  Total:"
    echo ""
    
    echo -e "${COLORS_YELLOW}[INFO]${COLORS_NC} Firewall status:"
    if command -v ufw &> /dev/null; then
        ufw status | sed 's/^/  /'
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --list-all | sed 's/^/  /'
    else
        echo "  No firewall detected (or iptables)"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Main loop
while true; do
    show_menu
    read choice
    
    case $choice in
        1)
            run_basic_tests
            echo ""
            read -p "Press Enter to continue..."
            ;;
        2)
            run_tunnel_test
            ;;
        3)
            monitor_tunnels
            ;;
        4)
            network_diagnostics
            ;;
        0)
            clear
            echo -e "${COLORS_CYAN}Goodbye!${COLORS_NC}\n"
            exit 0
            ;;
        *)
            echo -e "${COLORS_RED}Invalid option${COLORS_NC}"
            sleep 1
            ;;
    esac
done
