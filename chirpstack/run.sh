#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Add-on: ChirpStack 4.0
# ==============================================================================

bashio::log.info "Starting ChirpStack 4.0"

# ---------------------------------------------------------------------------
# Load HA Add-on config
# ---------------------------------------------------------------------------
mqtt_server=$(bashio::config 'mqtt.server')
mqtt_username=$(bashio::config 'mqtt.username')
mqtt_password=$(bashio::config 'mqtt.password')

chirpstack_log_level=$(bashio::config 'chirpstack.log_level')
chirpstack_api_bind=$(bashio::config 'chirpstack.api_bind')
chirpstack_api_secret=$(bashio::config 'chirpstack.api_secret')
chirpstack_network_id=$(bashio::config 'chirpstack.network_id')
chirpstack_database_dsn=$(bashio::config 'chirpstack.database_dsn')
region=$(bashio::config 'chirpstack.region')

gateway_bridge_log_level=$(bashio::config 'gateway_bridge.log_level')
basic_station_enabled=$(bashio::config 'gateway_bridge.basic_station.enabled')
basic_station_bind=$(bashio::config 'gateway_bridge.basic_station.bind')
packet_forwarder_enabled=$(bashio::config 'gateway_bridge.packet_forwarder.enabled')
packet_forwarder_bind=$(bashio::config 'gateway_bridge.packet_forwarder.bind')

concentratord_enabled=$(bashio::config 'concentratord.enabled')
concentratord_model=$(bashio::config 'concentratord.model')
concentratord_model_flags=$(bashio::config 'concentratord.model_flags')
concentratord_antenna_gain=$(bashio::config 'concentratord.antenna_gain')

bashio::log.info "MQTT: $mqtt_server"
bashio::log.info "Region: $region"
bashio::log.info "Basic Station enabled: $basic_station_enabled"
bashio::log.info "Semtech UDP enabled: $packet_forwarder_enabled"
bashio::log.info "Concentratord enabled: $concentratord_enabled"

# ---------------------------------------------------------------------------
# Reset configuration directory
# ---------------------------------------------------------------------------
rm -rf /config/chirpstack
mkdir -p /config/chirpstack
mkdir -p /config/chirpstack-gateway-bridge
mkdir -p /config/concentratord

mkdir -p /tmp/chirpstack_temp_config

# ---------------------------------------------------------------------------
# Generate ChirpStack config template
# ---------------------------------------------------------------------------
/usr/local/bin/chirpstack --config /tmp/chirpstack_temp_config configfile > /tmp/chirpstack.toml

# Remove duplicate "json" key in [logging] (chirpstack configfile outputs it twice)
awk '
  /^\[logging\]/ { in_logging=1 }
  /^\[/ && !/^\[logging\]/ { in_logging=0; json_seen=0 }
  in_logging && /json/ { json_seen++; if (json_seen > 1) next }
  { print }
' /tmp/chirpstack.toml > /tmp/chirpstack_fixed.toml
mv /tmp/chirpstack_fixed.toml /tmp/chirpstack.toml

# Apply user log level
tomlq -it \
  --arg lvl "$chirpstack_log_level" \
  '.logging.level=$lvl' \
  /tmp/chirpstack.toml

# ---------------------------------------------------------------------------
# Apply ChirpStack settings
# ---------------------------------------------------------------------------
tomlq -it \
  --arg bind "$chirpstack_api_bind" \
  '.api.bind=$bind' \
  /tmp/chirpstack.toml

tomlq -it \
  --arg secret "$chirpstack_api_secret" \
  '.api.secret=$secret' \
  /tmp/chirpstack.toml

tomlq -it \
  --arg nid "$chirpstack_network_id" \
  '.network.net_id=$nid' \
  /tmp/chirpstack.toml

# ---------------------------------------------------------------------------
# DATABASE: SQLite ONLY — ChirpStack 4.x correct schema
# Remove all other DB sections, rebuild storage.sqlite
# ---------------------------------------------------------------------------

bashio::log.info "Configuring SQLite database..."
# Remove all DB blocks that may exist
tomlq -it 'del(.storage)' /tmp/chirpstack.toml   2>/dev/null || true
tomlq -it 'del(.postgresql)' /tmp/chirpstack.toml   2>/dev/null || true
tomlq -it 'del(.sqlite)' /tmp/chirpstack.toml   2>/dev/null || true

# Create empty [storage] table
tomlq -it '.storage = {}' /tmp/chirpstack.toml
tomlq -it '.storage.sqlite = {}' /tmp/chirpstack.toml

# Assign SQLite path
tomlq -it \
  --arg dsn "$chirpstack_database_dsn" \
  '.storage.sqlite.path = $dsn' \
  /tmp/chirpstack.toml

# Add max_open_connections
tomlq -it \
  '.storage.sqlite.max_open_connections = 4' \
  /tmp/chirpstack.toml

# Add SQLite PRAGMAs
tomlq -it \
  '.storage.sqlite.pragmas = ["busy_timeout = 1000", "foreign_keys = ON"]' \
  /tmp/chirpstack.toml

# ---------------------------------------------------------------------------
# MQTT
# ---------------------------------------------------------------------------
tomlq -it \
  --arg srv "$mqtt_server" \
  '.integration.mqtt.server=$srv' \
  /tmp/chirpstack.toml

tomlq -it \
  --arg un "$mqtt_username" \
  '.integration.mqtt.username=$un' \
  /tmp/chirpstack.toml

tomlq -it \
  --arg pw "$mqtt_password" \
  '.integration.mqtt.password=$pw' \
  /tmp/chirpstack.toml

# Enable MQTT integration
tomlq -it '.integration.enabled=["mqtt"]' /tmp/chirpstack.toml

# Enable selected region
tomlq -it \
  --arg r "$region" \
  '.network.enabled_regions=[$r]' \
  /tmp/chirpstack.toml

# ---------------------------------------------------------------------------
# Region configuration — copy from static file and patch MQTT
# ---------------------------------------------------------------------------
REGION_FILE="/app/regions/${region}.toml"

if [[ ! -f "$REGION_FILE" ]]; then
    bashio::log.error "Region file not found: $REGION_FILE"
    bashio::log.error "Available regions:"
    ls /app/regions/ 2>/dev/null || echo "  (no region files found)"
    exit 1
fi

bashio::log.info "Loading region config from: $REGION_FILE"
cp "$REGION_FILE" "/config/chirpstack/region_${region}.toml"

# Patch MQTT credentials into the region file
tomlq -it \
  --arg srv "$mqtt_server" \
  '.regions[0].gateway.backend.mqtt.server=$srv' \
  "/config/chirpstack/region_${region}.toml"

tomlq -it \
  --arg un "$mqtt_username" \
  '.regions[0].gateway.backend.mqtt.username=$un' \
  "/config/chirpstack/region_${region}.toml"

tomlq -it \
  --arg pw "$mqtt_password" \
  '.regions[0].gateway.backend.mqtt.password=$pw' \
  "/config/chirpstack/region_${region}.toml"

# ---------------------------------------------------------------------------
# SAVE FINAL CHIRPSTACK CONFIG
# ---------------------------------------------------------------------------
cp /tmp/chirpstack.toml /config/chirpstack/chirpstack.toml


# ==============================================================================
#  GATEWAY BRIDGE CONFIGURATION
# ==============================================================================

if bashio::var.true "$basic_station_enabled" || bashio::var.true "$packet_forwarder_enabled"; then

    /usr/local/bin/chirpstack-gateway-bridge configfile > /tmp/chirpstack-gateway-bridge.toml

    # Update topic templates to include region prefix to match ChirpStack expectations
    tomlq -it \
      --arg r "$region" \
      '.integration.mqtt.event_topic_template=$r+"/gateway/{{ .GatewayID }}/event/{{ .EventType }}"' \
      /tmp/chirpstack-gateway-bridge.toml

    tomlq -it \
      --arg r "$region" \
      '.integration.mqtt.state_topic_template=$r+"/gateway/{{ .GatewayID }}/state/{{ .StateType }}"' \
      /tmp/chirpstack-gateway-bridge.toml

    tomlq -it \
      --arg r "$region" \
      '.integration.mqtt.command_topic_template=$r+"/gateway/{{ .GatewayID }}/command/#"' \
      /tmp/chirpstack-gateway-bridge.toml

    # LOG LEVEL convert to number
    case "$gateway_bridge_log_level" in
        "trace") log_lvl=5 ;;
        "debug") log_lvl=5 ;;
        "info")  log_lvl=4 ;;
        "warn")  log_lvl=3 ;;
        "error") log_lvl=2 ;;
        "fatal") log_lvl=1 ;;
        *) log_lvl=4 ;;
    esac

    tomlq -it \
      --argjson lvl "$log_lvl" \
      '.general.log_level=$lvl' \
      /tmp/chirpstack-gateway-bridge.toml

    # -----------------------------------------------------------------------
    # Set marshaler to JSON to match ChirpStack expectation
    # -----------------------------------------------------------------------
    tomlq -it '.integration.marshaler="json"' /tmp/chirpstack-gateway-bridge.toml

    # -----------------------------------------------------------------------
    # fake_rx_time=true
    # -----------------------------------------------------------------------

    tomlq -it '.backend.semtech_udp.fake_rx_time=true' /tmp/chirpstack-gateway-bridge.toml


    # -----------------------------------------------------------------------
    # Backend handling — remove disabled backends
    # -----------------------------------------------------------------------
    if bashio::var.true "$basic_station_enabled"; then

        tomlq -it \
          --arg b "$basic_station_bind" \
          '.backend.basic_station.bind=$b' \
          /tmp/chirpstack-gateway-bridge.toml

        if ! bashio::var.true "$packet_forwarder_enabled"; then
            tomlq -it 'del(.backend.semtech_udp)' /tmp/chirpstack-gateway-bridge.toml
        fi

    elif bashio::var.true "$packet_forwarder_enabled"; then

        tomlq -it \
          --arg b "$packet_forwarder_bind" \
          '.backend.semtech_udp.udp_bind=$b' \
          /tmp/chirpstack-gateway-bridge.toml

        tomlq -it 'del(.backend.basic_station)' /tmp/chirpstack-gateway-bridge.toml
    fi

    # -----------------------------------------------------------------------
    # MQTT parameters
    # -----------------------------------------------------------------------
    tomlq -it \
      --arg srv "$mqtt_server" \
      '.integration.mqtt.auth.generic.servers=[ $srv ]' \
      /tmp/chirpstack-gateway-bridge.toml

    tomlq -it \
      --arg un "$mqtt_username" \
      '.integration.mqtt.auth.generic.username=$un' \
      /tmp/chirpstack-gateway-bridge.toml

    tomlq -it \
      --arg pw "$mqtt_password" \
      '.integration.mqtt.auth.generic.password=$pw' \
      /tmp/chirpstack-gateway-bridge.toml


    # SAVE CONFIG
    cp /tmp/chirpstack-gateway-bridge.toml /config/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml
fi


# ==============================================================================
#  CONCENTRATORD CONFIGURATION
# ==============================================================================

if bashio::var.true "$concentratord_enabled"; then

    # Determine which concentratord binary to use based on the model
    case "$concentratord_model" in
        imst_ic880a|kerlink_ifemtocell|multitech_mtcap_lora_868|multitech_mtcap_lora_915|multitech_mtac_lora_h_868|multitech_mtac_lora_h_915|pi_supply_lora_gateway_hat|rak_2245|rak_2246|rak_2247|risinghf_rhf0m301|sandbox_lorago_port|wifx_lorix_one)
            CD_BINARY="chirpstack-concentratord-sx1301"
            ;;
        dragino_pg1302|elecrow_lr1302|miromico_gwc_02_lw_868|miromico_gwc_02_lw_915|mtcap3_003e00|mtcap3_003u00|multitech_mtac_003e00|multitech_mtac_003u00|rak_2287|rak_5146|seeed_wm1302|semtech_sx1302c470gw1|semtech_sx1302c868gw1|semtech_sx1302c915gw1|semtech_sx1302css868gw1|semtech_sx1302css915gw1|semtech_sx1302css923gw1|waveshare_sx1302_lorawan_gateway_hat)
            CD_BINARY="chirpstack-concentratord-sx1302"
            ;;
        multitech_mtac_lora_2g4|rak_5148|semtech_sx1280z3dsfgw1)
            CD_BINARY="chirpstack-concentratord-2g4"
            ;;
        *)
            bashio::log.error "Unknown concentratord model: $concentratord_model"
            exit 1
            ;;
    esac

    # Check that the binary exists (may not be available on amd64)
    if [[ ! -f "/usr/local/bin/$CD_BINARY" ]]; then
        bashio::log.warning "Concentratord binary not found: /usr/local/bin/$CD_BINARY"
        bashio::log.warning "Concentratord is only available on arm64/armv7hf architectures."
        bashio::log.warning "Disabling concentratord."
        concentratord_enabled=false
    else
        bashio::log.info "Concentratord binary: $CD_BINARY"
        bashio::log.info "Concentratord model: $concentratord_model"

        # Generate concentratord config
        cat > /tmp/concentratord.toml << 'CDEOF'
# Concentratord configuration.
[concentratord]
  log_level="DEBUG"
  log_to_syslog=false
  stats_interval="30s"
  disable_crc_filter=false

  [concentratord.api]
    event_bind="ipc:///tmp/concentratord_event"
    command_bind="ipc:///tmp/concentratord_command"

# LoRa gateway configuration.
[gateway]
  antenna_gain=0
  lorawan_public=true
CDEOF

        # Map ChirpStack region name to concentratord region name.
        # Concentratord doesn't distinguish sub-bands (e.g. au915 vs au915_2).
        case "$region" in
            eu868)        CD_REGION="EU868" ;;
            us915|us915_2) CD_REGION="US915" ;;
            cn470)        CD_REGION="CN470" ;;
            cn779)        CD_REGION="CN779" ;;
            eu433)        CD_REGION="EU433" ;;
            as923|as923_2|as923_3|as923_4) CD_REGION="AS923" ;;
            au915|au915_2) CD_REGION="AU915" ;;
            in865)        CD_REGION="IN865" ;;
            kr920)        CD_REGION="KR920" ;;
            ru864)        CD_REGION="RU864" ;;
            *)            CD_REGION=$(echo "$region" | tr '[:lower:]' '[:upper:]') ;;
        esac
        bashio::log.info "Concentratord region: $CD_REGION (from $region)"

        tomlq -it \
          --arg r "$CD_REGION" \
          '.gateway.region=$r' \
          /tmp/concentratord.toml

        # Set model
        tomlq -it \
          --arg m "$concentratord_model" \
          '.gateway.model=$m' \
          /tmp/concentratord.toml

        # Set model flags
        if [[ -n "$concentratord_model_flags" ]]; then
            IFS=',' read -ra FLAGS <<< "$concentratord_model_flags"
            FLAG_JSON="["
            for i in "${!FLAGS[@]}"; do
                FLAG=$(echo "${FLAGS[$i]}" | xargs)  # trim whitespace
                if [[ $i -gt 0 ]]; then
                    FLAG_JSON+=","
                fi
                FLAG_JSON+="\"$FLAG\""
            done
            FLAG_JSON+="]"
            tomlq -it \
              --argjson f "$FLAG_JSON" \
              '.gateway.model_flags=$f' \
              /tmp/concentratord.toml
        else
            tomlq -it '.gateway.model_flags=[]' /tmp/concentratord.toml
        fi

        # Set antenna gain
        tomlq -it \
          --argjson g "$concentratord_antenna_gain" \
          '.gateway.antenna_gain=$g' \
          /tmp/concentratord.toml

        # Time fallback
        tomlq -it '.gateway.time_fallback_enabled=true' /tmp/concentratord.toml

        # Save config to separate directory (not /config/chirpstack/ to avoid
        # ChirpStack trying to parse it as its own config)
        cp /tmp/concentratord.toml /config/concentratord/concentratord.toml
    fi
fi


# ==============================================================================
# START SERVICES
# ==============================================================================

bashio::log.info "Starting Redis..."
redis-server --daemonize yes --port 6379 --bind 127.0.0.1

sleep 2

# Start Concentratord (if enabled and binary exists)
if bashio::var.true "$concentratord_enabled" && [[ -f "/usr/local/bin/$CD_BINARY" ]]; then
    bashio::log.info "Starting Concentratord ($CD_BINARY)..."
    bashio::log.info "  Model: $concentratord_model | Region: $CD_REGION"
    bashio::log.info "  SPI: $(ls -la /dev/spidev0.0 2>/dev/null || echo 'NOT FOUND')"
    bashio::log.info "  I2C: $(ls -la /dev/i2c-1 2>/dev/null || echo 'NOT FOUND')"
    bashio::log.info "  GPIO: $(ls -la /dev/gpiochip0 2>/dev/null || echo 'NOT FOUND')"
    /usr/local/bin/$CD_BINARY \
        --config /config/concentratord/concentratord.toml &
    CD_PID=$!
    sleep 2
    if kill -0 $CD_PID 2>/dev/null; then
        bashio::log.info "Concentratord running. PID=$CD_PID"
    else
        bashio::log.warning "Concentratord failed to start (non-fatal, continuing)"
    fi
fi

bashio::log.info "Starting ChirpStack..."

/usr/local/bin/chirpstack --config /config/chirpstack &

CH_PID=$!

sleep 3
if kill -0 $CH_PID; then
    bashio::log.info "ChirpStack running. PID=$CH_PID"

    if [[ -f /config/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml ]]; then
        bashio::log.info "Starting Gateway Bridge..."
        /usr/local/bin/chirpstack-gateway-bridge \
            --config /config/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml &
    fi
else
    bashio::log.error "ChirpStack failed to start!"
fi

wait
