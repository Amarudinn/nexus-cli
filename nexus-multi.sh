#!/bin/bash
set -e

# ✅ Global configuration variables
DEFAULT_THREADS=8
NEXUS_START_FLAGS="--headless --max-threads $DEFAULT_THREADS"
BASE_DIR="/root/nexus-node"
IMAGE_NAME="nexus-node:latest"
BUILD_DIR="$BASE_DIR/build"
LOG_DIR="$BASE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"

# ✅ Check if jq is installed
command -v jq >/dev/null 2>&1 || {
    echo "❌ jq command is missing, please install it first: sudo apt install -y jq" >&2
    exit 1
}

# ✅ Optimize directory permissions
function init_dirs() {
    mkdir -p "$BUILD_DIR" "$LOG_DIR" "$CONFIG_DIR"
    chmod 755 "$LOG_DIR"
    sudo chown -R $USER:$USER "$BASE_DIR" 2>/dev/null || true
}

function check_docker() {
    if ! [ -x "$(command -v docker)" ]; then
        echo "Docker is not installed, installing now..."
        apt update
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        apt update && apt install -y docker-ce
        systemctl enable docker && systemctl start docker
    fi
}

function prepare_build_files() {
  mkdir -p "$BUILD_DIR"

  cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Base dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl git build-essential pkg-config libssl-dev \
    clang libclang-dev cmake jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install rustup + latest nightly
RUN curl --retry 3 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# Clone nexus-cli source
WORKDIR /app
RUN git clone --depth=1 https://github.com/nexus-xyz/nexus-cli.git

# Build
WORKDIR /app/nexus-cli/clients/cli
RUN cargo build --release && \
    strip target/release/nexus-network && \
    cp target/release/nexus-network /usr/local/bin/ && \
    chmod +x /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

  cat > "$BUILD_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e

case "$1" in
    --version|--help|version|help)
        exec nexus-network "$@"
        ;;
esac

: "${NODE_ID:?❌ NODE_ID environment variable must be set}"
: "${MAX_THREADS:=8}"

LOG_DIR="/nexus-data"
LOG_FILE="${LOG_DIR}/nexus-${NODE_ID}.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

echo "▶️ Starting node: $NODE_ID | Threads: $MAX_THREADS | Log file: $LOG_FILE"

exec nexus-network start \
    --node-id "$NODE_ID" \
    --max-threads "$MAX_THREADS" \
    --headless \
    2>&1 | tee -a "$LOG_FILE"
EOF

  chmod +x "$BUILD_DIR/entrypoint.sh"
}

# ✅ Add check for existing image
function build_image() {
    cd "$BUILD_DIR"
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        read -rp "Image already exists, do you want to rebuild? [y/N] " choice
        [[ "$choice" != [yY] ]] && return
    fi

    echo "🔧 Starting to build Docker image..."
    docker build --no-cache -t "$IMAGE_NAME" . || {
        echo "❌ Image build failed" >&2
        exit 1
    }

    echo "✅ Image build complete, version info:"
    docker run --rm --entrypoint nexus-network "$IMAGE_NAME" --version || {
        echo "⚠️ Version check failed" >&2
    }
}

function build_image_latest() {
    cd "$BUILD_DIR"
    echo "🔧 Updating to the latest official version..."
    docker build -t "$IMAGE_NAME" . || {
        echo "❌ Image build failed" >&2
        exit 1
    }
    echo "✅ Image update complete, current version:"
    docker run --rm --entrypoint nexus-network "$IMAGE_NAME" --version
}

function validate_node_id() {
    [[ "$1" =~ ^[0-9]+$ ]] || {
        echo "❌ node-id must be a number" >&2
        return 1
    }
    return 0
}

# ✅ Use global start parameters
function start_instances() {
    read -rp "Please enter the number of instances to create: " INSTANCE_COUNT
    [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || { echo "❌ Please enter a valid number"; exit 1; }

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        while true; do
            read -rp "Please enter the node-id for instance #$i: " NODE_ID
            validate_node_id "$NODE_ID" && break
        done

        # ✅ Enhanced conflict check
        if docker inspect "nexus-node-$i" &>/dev/null; then
            read -rp "Container nexus-node-$i already exists, do you want to replace it? [y/N] " choice
            if [[ "$choice" =~ ^[yY] ]]; then
                echo "🔄 Removing old container..."
                docker rm -f "nexus-node-$i" || {
                    echo "❌ Container removal failed, skipping this instance"
                    continue
                }
            else
                echo "⏩ Skipping instance nexus-node-$i"
                continue
            fi
        fi

        # Start new instance
        if ! docker run -dit \
            --name "nexus-node-$i" \
            -e NODE_ID="$NODE_ID" \
            -v "$LOG_DIR":/nexus-data \
            "$IMAGE_NAME" \
            start --node-id "$NODE_ID" --max-threads 8 --headless; then
            echo "❌ Instance nexus-node-$i failed to start"
            continue
        fi
        
        echo "✅ Instance nexus-node-$i started successfully (node-id: $NODE_ID)"
    done
}

function add_one_instance() {
    # Get the maximum number (compatible with non-numeric container names)
    MAX_ID=$(docker ps --filter "name=nexus-node-" --format '{{.Names}}' | 
             awk -F'-' '{if($NF ~ /^[0-9]+$/) print $NF}' | 
             sort -n | 
             tail -n 1)

    # Calculate the next available index
    NEXT_IDX=$(( ${MAX_ID:-0} + 1 ))

    while true; do
        read -rp "Please enter node-id (must be a number): " NODE_ID
        [[ "$NODE_ID" =~ ^[0-9]+$ ]] && break
        echo "❌ node-id must be a number!"
    done

    # Start instance
    docker run -dit \
        --name "nexus-node-${NEXT_IDX}" \
        -e NODE_ID="$NODE_ID" \
        -v "$LOG_DIR":/nexus-data \
        "$IMAGE_NAME" \
        start --node-id "$NODE_ID" --max-threads 8 --headless

    echo "✅ Instance nexus-node-${NEXT_IDX} started successfully (threads: 8)"
}

function restart_node() {
    containers=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^nexus-node-[0-9]+$ ]]; then
            containers+=("$line")
        fi
    done < <(docker ps --filter "name=nexus-node-" --format "{{.Names}}")

    if [ ${#containers[@]} -eq 0 ]; then
        echo "⚠️ No running instances"
        sleep 2
        return
    fi

    echo "Please select the node to restart:"
    for i in "${!containers[@]}"; do
        echo "[$((i+1))] ${containers[i]}"
    done
    echo "[a] Restart all nodes"
    echo "[0] Back"

    read -rp "Please enter your choice: " choice
    case "$choice" in
        [1-9])
            if [ "$choice" -le "${#containers[@]}" ]; then
                container="${containers[$((choice-1))]}"
                echo "🔄 Restarting $container ..."
                if ! timeout 10s docker restart "$container"; then
                    echo "❌ Restart timed out, trying to force stop..."
                    docker stop -t 2 "$container" && docker start "$container"
                fi
            fi
            ;;
        a|A)
            for container in "${containers[@]}"; do
                echo "🔄 Restarting $container ..."
                if ! timeout 10s docker restart "$container"; then
                    echo "❌ $container restart timed out, trying to force stop..."
                    docker stop -t 2 "$container" && docker start "$container"
                fi
            done
            ;;
    esac
    read -rp "Press Enter to continue..."
}
function calculate_uptime() {
    local container=$1
    local created=$(docker inspect --format '{{.Created}}' "$container")
    local restarts=$(docker inspect --format '{{.RestartCount}}' "$container")
    local started=$(docker inspect --format '{{.State.StartedAt}}' "$container")
    
    local now=$(date +%s)
    local created_ts=$(date -d "$created" +%s)
    local started_ts=$(date -d "$started" +%s)
    
    if [ "$restarts" -gt 0 ]; then
        local prev_uptime=$((created_ts - started_ts))
        local curr_uptime=$((now - started_ts))
        local total_seconds=$((prev_uptime + curr_uptime))
    else
        local total_seconds=$((now - started_ts))
    fi
    
    local hours=$((total_seconds / 3600))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    printf "%02dh%02dm" "$hours" "$minutes"
}
function show_container_logs() {
    containers=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^nexus-node-[0-9]+$ ]]; then
            containers+=("$line")
        fi
    done < <(docker ps --filter "name=nexus-node-" --format "{{.Names}}")

    while true; do
        clear
        echo "Nexus Node Log Viewer"
        echo "--------------------------------"

        if [ ${#containers[@]} -eq 0 ]; then
            echo "⚠️ No running instances"
            sleep 2
            return
        fi

        for i in "${!containers[@]}"; do
            status=$(docker inspect -f '{{.State.Status}}' "${containers[i]}")
            node_id=$(docker inspect "${containers[i]}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^NODE_ID=" | cut -d= -f2)
            echo "[$((i+1))] ${containers[i]} (Status: $status | Node ID: ${node_id:-Not Set})"
        done

        echo
        echo "[0] Back to main menu"
        read -rp "Please select a container: " input

        [[ "$input" == "0" ]] && return
        [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -le "${#containers[@]}" ] && {
            container="${containers[$((input-1))]}"
            clear
            echo "🔍 Real-time log: $container (Ctrl+C to exit)"
            echo "--------------------------------"
            trap "echo; return 0" SIGINT
            docker logs -f --tail=20 "$container"
            trap - SIGINT
            read -rp "Press Enter to continue..."
        }
    done
}

function show_menu() {
    # --- Color Definitions ---
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    YELLOW='\033[0;33m'
    PURPLE='\033[0;35m'
    RED='\033[0;31m'
    NC='\033[0m' # No Color

    clear
   # Green NEXUS title (block version)
    echo -e "${WHITE}"
    echo "███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗       ██████╗██╗     ██╗"
    echo "████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝      ██╔════╝██║     ██║"
    echo "██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗█████╗██║     ██║     ██║"
    echo "██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║╚════╝██║     ██║     ██║"
    echo "██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║      ╚██████╗███████╗██║"
    echo "╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝       ╚═════╝╚══════╝╚═╝"
    echo -e "${NC}"
    echo -e "${CYAN}                Nexus Node Management Console v2.1${NC}"

    # --- System & Docker Info ---
    total_containers=$(docker ps -a --filter "name=nexus-node-" | wc -l)
    running_containers=$(docker ps --filter "name=nexus-node-" | wc -l)
    cpu_cores=$(nproc)
    mem_free=$(free -h | awk '/^Mem:/{print $4}')

    echo -e "${BLUE}╭───────────────────────────────────────────────────────────────────────────────╮${NC}"
    printf "${BLUE}│ ${YELLOW}🖥️ System: ${GREEN}%-2s Cores / %-6s Free${NC} ${YELLOW}🐳 Docker: ${GREEN}%d Running / %d Total Nodes${NC}${BLUE}        │\n" "$cpu_cores" "$mem_free" "$((running_containers - 1))" "$((total_containers - 1))"
    echo -e "${BLUE}├───────────────────────────────────────────────────────────────────────────────┤${NC}"

    # --- Node Table Header ---
    printf "${BLUE}│ ${CYAN}%-15s ${BLUE}│ ${CYAN}%-10s ${BLUE}│ ${CYAN}%-8s ${BLUE}│ ${CYAN}%-8s ${BLUE}│ ${CYAN}%-10s ${BLUE}│ ${CYAN}%-12s${NC}${BLUE}│\n" "CONTAINER" "NODE ID" "UPTIME" "CPU %" "RAM USAGE" "TASKS"
    echo -e "${BLUE}├───────────────────────────────────────────────────────────────────────────────┤${NC}"

    # --- Node Table Body ---
    # Fetch all running container names first
    containers=$(docker ps --filter "name=nexus-node-" --format "{{.Names}}")
    if [ -z "$containers" ]; then
        echo -e "│ ${YELLOW}No running Nexus nodes found. Use option '2' to start instances.${NC}                  │"
    else
        # Use docker stats to get CPU and RAM for all containers at once for efficiency
        docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" $containers | while IFS=, read -r name cpu_perc mem_usage; do
            # Extract only the used memory part (e.g., "12.34MiB")
            ram=$(echo "$mem_usage" | awk '{print $1}')
            
            # Get other details
            node_id=$(docker inspect "$name" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "NODE_ID"}}{{(index (split . "=") 1)}}{{end}}{{end}}')
            uptime=$(calculate_uptime "$name")
            tasks=$(grep -c "Proof submitted" "${LOG_DIR}/nexus-${node_id}.log" 2>/dev/null || echo 0)

            # Print formatted row
            printf "${BLUE}│ ${CYAN}%-15s${NC} ${BLUE}│ ${GREEN}%-10s${NC} ${BLUE}│ ${YELLOW}%-8s${NC} ${BLUE}│ ${CYAN}%-8s${NC} ${BLUE}│ ${CYAN}%-10s${NC} ${BLUE}│ ${GREEN}%-4s tasks${NC} ${BLUE} │\n" \
                "$name" \
                "${node_id:-N/A}" \
                "$uptime" \
                "$cpu_perc" \
                "$ram" \
                "$tasks"
        done
    fi
    echo -e "${BLUE}╰───────────────────────────────────────────────────────────────────────────────╯${NC}"

    # --- Function Menu ---
    echo -e "${BLUE}╭─────────────────────────── ${CYAN}MENU ${BLUE}────────────────────────────╮${NC}"
    echo -e "${BLUE}│ ${CYAN}1. Build/Rebuild Image${NC}       ${BLUE}│ ${CYAN}5. Restart a Node${NC}          ${BLUE}│"
    echo -e "${BLUE}│ ${CYAN}2. Start Multiple Instances${NC}  ${BLUE}│ ${CYAN}6. Add One Instance${NC}        ${BLUE}│"
    echo -e "${BLUE}│ ${CYAN}3. Stop All Nodes${NC}            ${BLUE}│ ${CYAN}7. Update to Latest Code${NC}   ${BLUE}│"
    echo -e "${BLUE}│ ${CYAN}4. View Node Logs${NC}            ${BLUE}│ ${CYAN}0. Exit Program${NC}            ${BLUE}│"
    echo -e "${BLUE}╰─────────────────────────────────────────────────────────────╯${NC}"
}

# ========== Main Program ==========
# ========== Main Program ==========
check_docker
init_dirs

while true; do
    # Loop internal untuk real-time update
    while true; do
        show_menu
        # Membaca 1 karakter input dengan timeout 1 detik
        read -t 1 -N 1 choice
        # Jika ada input (exit code 0), hentikan loop real-time
        if [ $? -eq 0 ]; then
            break
        fi
    done

    # Proses pilihan pengguna di luar loop real-time
    case "$choice" in
        1) prepare_build_files; build_image;;
        2) start_instances;;
        3) docker rm -f $(docker ps -aq --filter "name=nexus-node-") 2>/dev/null || true;;
        4) show_container_logs;;
        5) restart_node;;
        6) add_one_instance;;
        7) prepare_build_files; build_image_latest;;
        0) echo "Exiting"; exit 0;;
        *) # Opsi tidak valid diabaikan dalam mode real-time
           ;;
    esac

    # Hanya minta "Press Enter" jika ada aksi yang dilakukan (bukan pilihan invalid)
    if [[ "$choice" =~ ^[0-7]$ ]]; then
        read -rp "Press Enter to continue..."
    fi
done
