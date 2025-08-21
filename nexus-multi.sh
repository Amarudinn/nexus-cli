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

# BAGIAN 1: DEPENDENSI STABIL (AKAN DI-CACHE)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl git build-essential pkg-config libssl-dev \
    clang libclang-dev cmake jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN curl --retry 3 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# BAGIAN 2: KODE SUMBER (CLONE PERTAMA KALI)
WORKDIR /app
RUN git clone --depth=1 https://github.com/nexus-xyz/nexus-cli.git

# ✅ BAGIAN 3: LOGIKA UPDATE DAN BUILD YANG PINTAR
ARG CACHE_BUSTER=
WORKDIR /app/nexus-cli
# 'RUN' ini sekarang berisi logika untuk memeriksa sebelum membangun.
RUN \
  echo "Cache buster: $CACHE_BUSTER" && \
  echo "▶️ Checking for nexus-cli updates..." && \
  git config --global --add safe.directory /app/nexus-cli && \
  # 1. Simpan hash commit saat ini (sebelum update)
  OLD_HASH=$(git rev-parse HEAD) && \
  # 2. Lakukan git pull untuk mengambil pembaruan
  git pull && \
  # 3. Dapatkan hash commit yang baru (setelah update)
  NEW_HASH=$(git rev-parse HEAD) && \
  # 4. Bandingkan kedua hash
  if [ "$OLD_HASH" = "$NEW_HASH" ]; then \
    # 5. JIKA SAMA: Tidak ada pembaruan, lewati proses build
    echo "✅ Already on the latest version. Build process skipped." ; \
  else \
    # 6. JIKA BERBEDA: Ada pembaruan, jalankan proses build
    echo "🔄 New version detected, starting build process..." && \
    cd /app/nexus-cli/clients/cli && \
    cargo build --release && \
    strip target/release/nexus-network && \
    cp target/release/nexus-network /usr/local/bin/ && \
    chmod +x /usr/local/bin/nexus-network ; \
  fi

# BAGIAN 4: FINALISASI IMAGE
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

  # Salin entrypoint.sh (tidak ada perubahan di sini)
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
    echo "🔧 Updating to the latest official version (fast method)..."
    
    # Kita kirim 'build argument' dengan nilai waktu saat ini.
    # Ini memastikan lapisan 'git pull' di Dockerfile selalu dianggap baru
    # dan dijalankan ulang, sementara lapisan sebelumnya tetap dari cache.
    docker build \
        --build-arg CACHE_BUSTER=$(date +%s) \
        -t "$IMAGE_NAME" . || {
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
        echo -e "\033[36m📝 Nexus Node Log Viewer\033[0m"
        echo -e "\033[34m--------------------------------\033[0m"

        if [ ${#containers[@]} -eq 0 ]; then
            echo -e "⚠️  \033[31mNo running instances\033[0m"
            sleep 2
            return
        fi

        for i in "${!containers[@]}"; do
            status=$(docker inspect -f '{{.State.Status}}' "${containers[i]}")
            node_id=$(docker inspect "${containers[i]}" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^NODE_ID=" | cut -d= -f2)
            echo -e "[$((i+1))] ${containers[i]} (Status: \033[32m$status\033[0m | Node ID: ${node_id:-Not Set})"
        done

        echo
        echo "[0] Back to main menu"
        read -rp "Please select a container: " input

        [[ "$input" == "0" ]] && return
        [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -le "${#containers[@]}" ] && {
            container="${containers[$((input-1))]}"
            clear
            echo -e "🔍 \033[36mReal-time log:\033[0m $container (\033[33mCtrl+C to exit\033[0m)"
            echo -e "\033[34m--------------------------------\033[0m"

            trap "echo; return 0" SIGINT
            docker logs -f --tail=20 "$container" 2>&1 | while IFS= read -r line; do
                if [[ "$line" == *"Waiting"* ]] || [[ "$line" == *"Task completed"* ]] || [[ "$line" == *"Fetching task"* ]]; then
                    echo -e "\033[36m$line\033[0m"   # Cyan
                elif [[ "$line" == *"Proof generated for task"* ]]; then
                    echo -e "\033[33m$line\033[0m"   # Kuning
                elif [[ "$line" == *"Got task"* ]] || [[ "$line" == *"Proving task"* ]] || [[ "$line" == *"Proof submitted successfully"* ]] || [[ "$line" == *"Submitting proof for task"* ]]; then
                    echo -e "\033[32m$line\033[0m"   # Hijau
                elif [[ "$line" == *"Error"* ]] || [[ "$line" == *"Failed"* ]] || [[ "$line" == *"ERROR"* ]]; then
                    echo -e "\033[31m$line\033[0m"   # Merah
                else
                    echo "$line"                     # Default (tanpa warna)
                fi
            done
            trap - SIGINT
            read -rp "Press Enter to continue..."
        }
    done
}

function show_menu() {
    clear
   # Green NEXUS title (block version)
    echo -e "${GREEN}"
    echo "███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗       ██████╗██╗     ██╗"
    echo "████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝      ██╔════╝██║     ██║"
    echo "██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗█████╗██║     ██║     ██║"
    echo "██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║╚════╝██║     ██║     ██║"
    echo "██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║      ╚██████╗███████╗██║"
    echo "╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝       ╚═════╝╚══════╝╚═╝"
    echo -e "${NC}"
    
    # Subtitle
    echo -e "\n${CYAN}                🚀 NEXUS Node Management Console v2.2 🚀${NC}"
    echo -e "${BLUE}==================================================================================${NC}\n"

    # System resources
    printf " ${YELLOW}🖥️  System Resources ${BLUE}| CPU:${GREEN} %-2d core ${BLUE}| Memory:${GREEN} %-5s${NC}\n" \
        $(nproc) $(free -h | awk '/Mem:/{print $4}')
    echo -e "${BLUE}----------------------------------------------------------------------------------${NC}"

    # ✅ HEADER TABEL BARU DENGAN KOLOM THREADS
    printf "${CYAN}%-16s %-10s %-8s %-9s %-8s %-10s %-16s${NC}\n" \
        "Container Name" "Node ID" "CPU" "RAM" "Threads" "Uptime" "Tasks Completed"
    echo -e "${BLUE}----------------------------------------------------------------------------------${NC}"

    # Mendapatkan daftar kontainer nexus yang berjalan
    running_containers=$(docker ps --filter "name=nexus-node-" --format "{{.Names}}")

    if [ -z "$running_containers" ]; then
        echo -e "  ⚠️  No running instances found."
    else
        # Loop melalui setiap kontainer yang berjalan
        while read -r name; do
            node_id=$(docker inspect "$name" --format '{{.Config.Env}}' | grep -o 'NODE_ID=[0-9]*' | cut -d= -f2)
            uptime=$(calculate_uptime "$name")
            tasks=$(grep -c "Proof submitted" "/root/nexus-node/logs/nexus-${node_id}.log" 2>/dev/null || echo 0)
            
            # Mendapatkan stats CPU & RAM
            stats_line=$(docker stats --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}" "$name" 2>/dev/null)
            if [[ -n "$stats_line" ]]; then
                cpu_usage=$(echo "$stats_line" | cut -d'|' -f1)
                mem_usage=$(echo "$stats_line" | cut -d'|' -f2 | awk '{print $1}')
            else
                cpu_usage="N/A"
                mem_usage="N/A"
            fi
            
            # ✅ MENDAPATKAN JUMLAH THREADS DARI KONFIGURASI KONTAINER
            # Mengambil argumen start (--max-threads) dari metadata kontainer
            threads=$(docker inspect -f '{{.Config.Cmd}}' "$name" | tr ' ' '\n' | grep -A 1 -E -- "--max-threads" | tail -n 1 || echo "N/A")

            # ✅ PRINTF BARU DENGAN DATA THREADS
            printf "${PURPLE}%-16s${NC} ${GREEN}%-10s${NC} ${CYAN}%-8s${NC} ${CYAN}%-9s${NC} ${GREEN}%-8s${NC} ${YELLOW}%-10s${NC} ${RED}%-16s${NC}\n" \
                "$name" "$node_id" "$cpu_usage" "$mem_usage" "$threads" "$uptime" "$tasks tasks"

        done <<< "$running_containers"
    fi

    # Function menu
    echo -e "\n${BLUE}==================================================================================${NC}"
    echo -e "${CYAN}                            ⚙️  Function Menu Options ⚙️${NC}"
    echo -e "${BLUE}----------------------------------------------------------------------------------${NC}"
    echo -e " ${GREEN}[1]${NC} Build Image      ${GREEN}[2]${NC} Start Instances    ${GREEN}[3]${NC} Stop All"
    echo -e " ${GREEN}[4]${NC} View Logs        ${GREEN}[5]${NC} Restart Node       ${GREEN}[6]${NC} Add Instance"
    echo -e " ${GREEN}[7]${NC} Update Version   ${GREEN}[0]${NC} Exit"
    echo -e "${BLUE}==================================================================================${NC}\n"
}

# ========== Main Program ==========
check_docker
init_dirs

while true; do
    show_menu
    read -rp "Please select an option: " choice
    case "$choice" in
        1) prepare_build_files; build_image;;
        2) start_instances;;
        3) docker rm -f $(docker ps -aq --filter "name=nexus-node-") 2>/dev/null || true;;
        4) show_container_logs;;
        5) restart_node;;
        6) add_one_instance ;;
        7) prepare_build_files; build_image_latest ;;
        0) echo "Exiting"; exit 0;;
        *) echo "Invalid option";;
    esac
    read -rp "Press Enter to continue..."
done
