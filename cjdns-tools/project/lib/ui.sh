#!/usr/bin/env bash
# UI Module - Interactive prompts and user input validation

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# ASCII Art Header
print_ascii_header() {
    echo -e "${CYAN}"
    echo "   (╯°□°)╯︵  P E E R S"
    echo "        └──CJDNS─PeerYeeter──┘"
    echo -e "${NC}"
}

# Print colored message
print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Ask yes/no question (only accepts y/n)
ask_yes_no() {
    local prompt="$1"
    local response

    while true; do
        read -p "$prompt (y/n): " -r response
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            *)
                print_error "Please answer 'y' or 'n'"
                ;;
        esac
    done
}

# Ask user to select from a list
ask_selection() {
    local prompt="$1"
    shift
    local options=("$@")
    local selection

    if [ ${#options[@]} -eq 0 ]; then
        return 1
    fi

    echo "$prompt"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done

    while true; do
        read -p "Enter selection (1-${#options[@]}): " -r selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#options[@]} ]; then
            echo "${options[$((selection-1))]}"
            return 0
        else
            print_error "Invalid selection. Please enter a number between 1 and ${#options[@]}"
        fi
    done
}

# Ask for text input
ask_input() {
    local prompt="$1"
    local default="$2"
    local response

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " -r response
        echo "${response:-$default}"
    else
        while true; do
            read -p "$prompt: " -r response
            if [ -n "$response" ]; then
                echo "$response"
                return 0
            else
                print_error "Input cannot be empty"
            fi
        done
    fi
}

# Print section header
print_header() {
    local title="$1"
    local width=60
    echo
    echo "$(printf '=%.0s' $(seq 1 $width))"
    echo "$title"
    echo "$(printf '=%.0s' $(seq 1 $width))"
    echo
}

# Print sub-header
print_subheader() {
    local title="$1"
    echo
    echo "$title"
    echo "$(printf -- '-%.0s' $(seq 1 ${#title}))"
}
