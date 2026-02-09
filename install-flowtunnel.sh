#!/bin/bash

# FlowTunnel Auto Installer
# One-command installation and execution

clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FlowTunnel - Anti-DPI Tunnel Manager"
echo "  Auto Installer v1.0"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    echo "Please run: sudo bash install.sh"
    exit 1
fi

echo "📥 Downloading FlowTunnel..."

# Try wget first, then curl
if command -v wget &> /dev/null; then
    if ! wget -q --show-progress https://raw.githubusercontent.com/skyboy610/flowtunnel/flowtunnel.sh -O /usr/local/bin/flowtunnel 2>/dev/null; then
        echo "⚠️  Using local installation method..."
        # If download fails, use the current directory
        if [[ -f "./flowtunnel.sh" ]]; then
            cp ./flowtunnel.sh /usr/local/bin/flowtunnel
        else
            echo "❌ Installation failed. flowtunnel.sh not found."
            exit 1
        fi
    fi
elif command -v curl &> /dev/null; then
    if ! curl -# -L https://raw.githubusercontent.com/skyboy610/flowtunnel/flowtunnel.sh -o /usr/local/bin/flowtunnel 2>/dev/null; then
        echo "⚠️  Using local installation method..."
        if [[ -f "./flowtunnel.sh" ]]; then
            cp ./flowtunnel.sh /usr/local/bin/flowtunnel
        else
            echo "❌ Installation failed. flowtunnel.sh not found."
            exit 1
        fi
    fi
else
    echo "⚠️  Neither wget nor curl found, using local file..."
    if [[ -f "./flowtunnel.sh" ]]; then
        cp ./flowtunnel.sh /usr/local/bin/flowtunnel
    else
        echo "❌ Installation failed. flowtunnel.sh not found."
        exit 1
    fi
fi

echo "⚙️  Setting up FlowTunnel..."
chmod +x /usr/local/bin/flowtunnel

# Create command aliases
echo "🔗 Creating command aliases..."

# For bash
if [ -f ~/.bashrc ]; then
    if ! grep -q "alias flow=" ~/.bashrc 2>/dev/null; then
        echo "alias flow='flowtunnel'" >> ~/.bashrc
        echo "alias ft='flowtunnel'" >> ~/.bashrc
    fi
fi

# For zsh
if [ -f ~/.zshrc ]; then
    if ! grep -q "alias flow=" ~/.zshrc 2>/dev/null; then
        echo "alias flow='flowtunnel'" >> ~/.zshrc
        echo "alias ft='flowtunnel'" >> ~/.zshrc
    fi
fi

# Create symlinks
ln -sf /usr/local/bin/flowtunnel /usr/local/bin/flow 2>/dev/null
ln -sf /usr/local/bin/flowtunnel /usr/local/bin/ft 2>/dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Available commands:"
echo "  • flowtunnel"
echo "  • flow"
echo "  • ft"
echo ""
echo "Features:"
echo "  ✓ Connection Rotation (Anti-DPI)"
echo "  ✓ Session Breaking"
echo "  ✓ Traffic Obfuscation"
echo "  ✓ No TCP-over-TCP Meltdown"
echo "  ✓ Optimized for VPN Traffic"
echo ""
echo "🚀 Starting FlowTunnel..."
sleep 2

# Run FlowTunnel
exec /usr/local/bin/flowtunnel
