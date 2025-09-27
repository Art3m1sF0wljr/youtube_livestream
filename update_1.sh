#!/bin/bash

# Stream configuration for Camera Module v1
WIDTH=1296
HEIGHT=972
FRAMERATE=30
BITRATE=20000000
INTRA=$((FRAMERATE * 2))

# Nighttime configuration
NIGHT_SHUTTER=2900000  # 2 seconds in microseconds
NIGHT_GAIN=20.0
NIGHT_FRAMERATE=1       # 1 fps input

# YouTube configuration
URL="rtmp://a.rtmp.youtube.com/live2"
KEY="" # Your YouTube stream key

# Location configuration (Rome, Italy)
LAT=45.14
LON=7.38
TIMEZONE="Europe/Rome"

# Buffer times (30 minutes = 0.5 hours in decimal)
DAYTIME_BUFFER=0  # minutes
ALBA_BUFFER=0

# Camera initialization times (in seconds)
DAYTIME_INIT_TIME=10
NIGHTTIME_INIT_TIME=30

# Verbosity settings
VERBOSE=true
LOG_FILE="/tmp/stream_log_$(date +%Y%m%d_%H%M%S).txt"
FFMPEG_VERBOSITY="-loglevel warning"  # Can be: quiet, panic, fatal, error, warning, info, verbose, debug
RPICAM_VERBOSITY="--verbose"  # Remove for less verbosity

# Function to log messages
log_message() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Function to log verbose messages (only if VERBOSE=true)
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        log_message "[VERBOSE] $1"
    fi
}

# Function to log process output
log_process() {
    local process_name="$1"
    local message="$2"
    log_message "[$process_name] $message"
}

# Function to get sunset and sunrise times from API
get_sun_times() {
    local url="https://api.sunrise-sunset.org/json?lat=$LAT&lng=$LON&formatted=0"
    log_verbose "Fetching sun times from API: $url"
    local response=$(curl -s "$url")

    # Extract sunrise and sunset times (UTC)
    local sunrise_utc=$(echo "$response" | grep -o '"sunrise":"[^"]*' | cut -d'"' -f4)
    local sunset_utc=$(echo "$response" | grep -o '"sunset":"[^"]*' | cut -d'"' -f4)

    # Convert to local time (Rome time) and adjust with buffer
    local sunrise_local=$(date -d "$sunrise_utc" +%H%M)
    local sunset_local=$(date -d "$sunset_utc" +%H%M)

    # Calculate adjusted times (30 minutes buffer)
    SUNRISE_TIME=$(date -d "$sunrise_local today - $ALBA_BUFFER minutes" +%H%M)
    SUNSET_TIME=$(date -d "$sunset_local today + $DAYTIME_BUFFER minutes" +%H%M)

    log_message "Today's actual sunrise: $sunrise_local, sunset: $sunset_local (Rome time)"
    log_message "Adjusted daytime period: $SUNRISE_TIME to $SUNSET_TIME (with ${DAYTIME_BUFFER}min buffer)"
}

# Function to check if it's nighttime
is_nighttime() {
    local current_time=$(date +%H%M)
    log_verbose "Checking if nighttime: current_time=$current_time, sunrise=$SUNRISE_TIME, sunset=$SUNSET_TIME"

    # If current time is after adjusted sunset OR before adjusted sunrise, it's nighttime
    if [ "$current_time" -ge "$SUNSET_TIME" ] || [ "$current_time" -lt "$SUNRISE_TIME" ]; then
        log_verbose "It's nighttime"
        return 0  # It's nighttime
    else
        log_verbose "It's daytime"
        return 1  # It's daytime
    fi
}

# Function to wait for camera initialization
wait_for_camera() {
    local camera_pid=$1
    local init_time=$2
    local wait_time=0
    
    log_message "Waiting for camera to initialize (this may take ${init_time} seconds)..."
    
    # First, wait for the process to be running
    while [ $wait_time -lt $init_time ]; do
        if ! kill -0 $camera_pid 2>/dev/null; then
            log_message "ERROR: Camera process died during initialization"
            return 1
        fi
        
        # Check every second
        sleep 1
        ((wait_time++))
        
        # Show progress every 5 seconds
        if (( wait_time % 5 == 0 )); then
            log_verbose "Camera initializing... ${wait_time}/${init_time} seconds"
        fi
    done
    
    # Extra safety wait to ensure camera is fully ready
    sleep 2
    log_message "Camera initialization complete"
    return 0
}

# Function to create stream pipeline
create_stream_pipeline() {
    local is_night=$1
    local fifo_pipe="/tmp/stream_fifo_$$"
    
    # Clean up any existing FIFO
    rm -f "$fifo_pipe"
    
    # Create named pipe
    if ! mkfifo "$fifo_pipe"; then
        log_message "ERROR: Failed to create FIFO $fifo_pipe"
        return 1
    fi
    
    log_verbose "Created FIFO: $fifo_pipe"
    
    if [ $is_night -eq 0 ]; then
        log_message "Using NIGHTTIME mode: long exposure (2s), high gain"
        local init_time=$NIGHTTIME_INIT_TIME
        
        # Build rpicam-vid command
        local rpicam_cmd="rpicam-vid -n -t 0 \
            --width $WIDTH --height $HEIGHT \
            --framerate $NIGHT_FRAMERATE \
            --shutter $NIGHT_SHUTTER \
            --gain $NIGHT_GAIN \
            --codec h264 \
            --bitrate $BITRATE \
            --intra $((NIGHT_FRAMERATE * 2)) \
            --profile high \
            --inline \
            --denoise cdn_off \
            --awb auto \
            $RPICAM_VERBOSITY \
            --output -"
        
        log_verbose "Starting rpicam-vid command: $rpicam_cmd > $fifo_pipe"
        log_process "RPICAM" "Starting nighttime mode (PID: $$)"
        
        # Start rpicam-vid writing to FIFO in background
        eval "$rpicam_cmd > \"$fifo_pipe\" 2>&1 &"
        
        local camera_pid=$!
        
        # Wait for camera to initialize completely
        if ! wait_for_camera $camera_pid $init_time; then
            rm -f "$fifo_pipe"
            return 1
        fi
        
        log_message "Camera started successfully (PID: $camera_pid), starting ffmpeg..."
        
        # Build ffmpeg command
        local ffmpeg_cmd="ffmpeg $FFMPEG_VERBOSITY -fflags +genpts -flags low_delay \
            -f h264 -r $NIGHT_FRAMERATE \
            -i \"$fifo_pipe\" \
            -stream_loop -1 -i audio.mp3 \
            -c:v libx264 \
            -b:v $BITRATE \
            -r $FRAMERATE \
            -g $INTRA \
            -keyint_min $FRAMERATE \
            -preset veryfast \
            -tune zerolatency \
            -c:a aac \
            -shortest \
            -f flv \"${URL}/${KEY}\""
        
        log_verbose "Starting ffmpeg command: $ffmpeg_cmd"
        log_process "FFMPEG" "Starting transcoding mode (nighttime)"
        
        # Start ffmpeg that reads from the FIFO
        eval "$ffmpeg_cmd 2>&1 &"
        
        local ffmpeg_pid=$!
        
    else
        log_message "Using DAYTIME mode: normal exposure"
        local init_time=$DAYTIME_INIT_TIME
        
        # Build rpicam-vid command
        local rpicam_cmd="rpicam-vid -n -t 0 \
            --width $WIDTH --height $HEIGHT \
            --framerate $FRAMERATE \
            --codec h264 \
            --bitrate $BITRATE \
            --intra $INTRA \
            --profile high \
            --inline \
            --denoise cdn_off \
            --awb auto \
            $RPICAM_VERBOSITY \
            --output -"
        
        log_verbose "Starting rpicam-vid command: $rpicam_cmd > $fifo_pipe"
        log_process "RPICAM" "Starting daytime mode (PID: $$)"
        
        # Start rpicam-vid writing to FIFO in background
        eval "$rpicam_cmd > \"$fifo_pipe\" 2>&1 &"
        
        local camera_pid=$!
        
        # Wait for camera to initialize completely
        if ! wait_for_camera $camera_pid $init_time; then
            rm -f "$fifo_pipe"
            return 1
        fi
        
        log_message "Camera started successfully (PID: $camera_pid), starting ffmpeg..."
        
        # Build ffmpeg command
        local ffmpeg_cmd="ffmpeg $FFMPEG_VERBOSITY -fflags +genpts -flags low_delay \
            -f h264 -r $FRAMERATE \
            -i \"$fifo_pipe\" \
            -stream_loop -1 -i audio.mp3 \
            -c:v copy \
            -c:a aac \
            -shortest \
            -g $INTRA \
            -f flv \"${URL}/${KEY}\""
        
        log_verbose "Starting ffmpeg command: $ffmpeg_cmd"
        log_process "FFMPEG" "Starting copy mode (daytime)"
        
        # Start ffmpeg that reads from the FIFO
        eval "$ffmpeg_cmd 2>&1 &"
        
        local ffmpeg_pid=$!
    fi
    
    # Wait a moment for ffmpeg to start
    sleep 2
    
    # Verify both processes are running
    if ! kill -0 $camera_pid 2>/dev/null; then
        log_message "ERROR: Camera process failed after startup"
        kill $ffmpeg_pid 2>/dev/null
        rm -f "$fifo_pipe"
        return 1
    fi
    
    if ! kill -0 $ffmpeg_pid 2>/dev/null; then
        log_message "ERROR: FFmpeg process failed to start"
        kill $camera_pid 2>/dev/null
        rm -f "$fifo_pipe"
        return 1
    fi
    
    log_message "Both camera and ffmpeg processes are running successfully"
    log_verbose "Camera PID: $camera_pid, FFmpeg PID: $ffmpeg_pid"
    echo "$camera_pid $ffmpeg_pid $fifo_pipe"
    return 0
}

# Function to log system status
log_system_status() {
    if [ "$VERBOSE" = true ]; then
        local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
        local mem_usage=$(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2}')
        local disk_usage=$(df -h / | awk 'NR==2{print $5}')
        local temp=$(vcgencmd measure_temp | cut -d= -f2)
        
        log_verbose "System Status - CPU: $cpu_usage, Memory: $mem_usage, Disk: $disk_usage, Temp: $temp"
    fi
}

# Function to cleanup on exit
cleanup() {
    log_message "Cleaning up..."
    log_message "Killing camera PID: $CAMERA_PID"
    log_message "Killing ffmpeg PID: $FFMPEG_PID"
    kill $CAMERA_PID 2>/dev/null
    kill $FFMPEG_PID 2>/dev/null
    log_verbose "Removing FIFO: $FIFO_PIPE"
    rm -f "$FIFO_PIPE"
    log_message "Stream stopped successfully"
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Initialize logging
log_message "=== Starting YouTube Stream ==="
log_message "Stream configuration: ${WIDTH}x${HEIGHT} @ ${FRAMERATE}fps, Bitrate: $((BITRATE/1000))kbps"
log_message "Log file: $LOG_FILE"
log_message "Verbose mode: $VERBOSE"

# Initialize sun times
get_sun_times
LAST_SUN_UPDATE=$(date +%s)

# Main loop
while true; do
    # Update sun times once per day (at midnight)
    current_date=$(date +%Y%m%d)
    last_update_date=$(date -d "@$LAST_SUN_UPDATE" +%Y%m%d)

    if [ "$current_date" != "$last_update_date" ]; then
        log_message "New day detected, updating sun times..."
        get_sun_times
        LAST_SUN_UPDATE=$(date +%s)
    fi

    # Determine if nighttime
    if is_nighttime; then
        night_mode=0
        log_message "It's nighttime - using nighttime settings (${NIGHTTIME_INIT_TIME}s initialization)"
    else
        night_mode=1
        log_message "It's daytime - using daytime settings (${DAYTIME_INIT_TIME}s initialization)"
    fi

    # Start the stream pipeline
    log_message "Starting new stream session..."
    result=$(create_stream_pipeline $night_mode)
    
    if [ $? -ne 0 ]; then
        log_message "Failed to start stream pipeline, retrying in 10 seconds..."
        sleep 10
        continue
    fi
    
    CAMERA_PID=$(echo $result | cut -d' ' -f1)
    FFMPEG_PID=$(echo $result | cut -d' ' -f2)
    FIFO_PIPE=$(echo $result | cut -d' ' -f3)
    
    log_message "Stream started successfully!"
    log_message "Camera PID: $CAMERA_PID, FFmpeg PID: $FFMPEG_PID, FIFO: $FIFO_PIPE"
    
    # Log system status at startup
    log_system_status
    
    # Calculate remaining time (30 minutes minus initialization time)
    if [ $night_mode -eq 0 ]; then
        stream_duration=$((1800 - NIGHTTIME_INIT_TIME))
    else
        stream_duration=$((1800 - DAYTIME_INIT_TIME))
    fi
    
    log_message "Streaming for $((stream_duration / 60)) minutes before camera restart..."
    
    # Countdown timer
    for ((i=stream_duration; i>0; i--)); do
        if ! kill -0 $CAMERA_PID 2>/dev/null || ! kill -0 $FFMPEG_PID 2>/dev/null; then
            log_message "One of the processes died prematurely, restarting..."
            break
        fi
        
        # Log system status every 5 minutes
        if (( i % 300 == 0 )); then
            log_system_status
        fi
        
        # Update status every minute
        if (( i % 60 == 0 )); then
            current_time=$(date +%H%M)
            local minutes_remaining=$((i/60))
            log_message "$minutes_remaining minutes remaining - Current time: $current_time"
            
            # Check if we need to switch modes
            if is_nighttime && [ $night_mode -eq 1 ]; then
                log_message "Mode switch detected: switching to nighttime mode..."
                break
            elif ! is_nighttime && [ $night_mode -eq 0 ]; then
                log_message "Mode switch detected: switching to daytime mode..."
                break
            fi
        fi
        
        sleep 1
    done
    
    # Restart camera process only
    log_message "Restarting camera process (PID: $CAMERA_PID)..."
    kill $CAMERA_PID 2>/dev/null
    wait $CAMERA_PID 2>/dev/null
    
    # Small delay before cleanup
    sleep 2
    
    # Clean up the FIFO
    log_verbose "Removing FIFO: $FIFO_PIPE"
    rm -f "$FIFO_PIPE"
    
    log_message "Camera stopped, ffmpeg continues running..."
    log_message "Waiting 5 seconds before restarting camera..."
    sleep 5
done
