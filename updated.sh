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

# Function to get sunset and sunrise times from API
get_sun_times() {
    local url="https://api.sunrise-sunset.org/json?lat=$LAT&lng=$LON&formatted=0"
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

    echo "Today's actual sunrise: $sunrise_local, sunset: $sunset_local (Rome time)"
    echo "Adjusted daytime period: $SUNRISE_TIME to $SUNSET_TIME (with ${DAYTIME_BUFFER}min buffer)"
}

# Function to check if it's nighttime
is_nighttime() {
    local current_time=$(date +%H%M)

    # If current time is after adjusted sunset OR before adjusted sunrise, it's nighttime
    if [ "$current_time" -ge "$SUNSET_TIME" ] || [ "$current_time" -lt "$SUNRISE_TIME" ]; then
        return 0  # It's nighttime
    else
        return 1  # It's daytime
    fi
}

# Function to wait for file to be created and have content
wait_for_file() {
    local file="$1"
    local max_wait=30  # Maximum 30 seconds wait
    local wait_time=0
    
    while [ ! -f "$file" ] && [ $wait_time -lt $max_wait ]; do
        sleep 1
        ((wait_time++))
        echo "Waiting for camera to create file... ($wait_time seconds)"
    done
    
    if [ ! -f "$file" ]; then
        echo "ERROR: File $file was not created within $max_wait seconds"
        return 1
    fi
    
    # Wait a bit more for content to start flowing
    sleep 2
    return 0
}

# Function to create stream pipeline
create_stream_pipeline() {
    local is_night=$1
    local buffer_file="/tmp/stream_buffer_$$.h264"
    
    # Clean up any existing file
    rm -f "$buffer_file"
    
    if [ $is_night -eq 0 ]; then
        echo "Using NIGHTTIME mode: long exposure (2s), high gain"
        
        # Start rpicam-vid writing to buffer file in background
        echo "Starting rpicam-vid (this may take 20+ seconds)..."
        rpicam-vid -n -t 0 \
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
            --output "$buffer_file" &
        
        local camera_pid=$!
        
        # Wait for file to be created and have content
        if ! wait_for_file "$buffer_file"; then
            kill $camera_pid 2>/dev/null
            return 1
        fi
        
        echo "Camera started successfully, starting ffmpeg..."
        
        # Start ffmpeg that reads from the buffer file
        ffmpeg -re -fflags +genpts -flags low_delay \
            -f h264 -r $NIGHT_FRAMERATE \
            -i "$buffer_file" \
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
            -f flv "${URL}/${KEY}" &
        
        local ffmpeg_pid=$!
        
    else
        echo "Using DAYTIME mode: normal exposure"
        
        # Start rpicam-vid writing to buffer file in background
        echo "Starting rpicam-vid (this may take 20+ seconds)..."
        rpicam-vid -n -t 0 \
            --width $WIDTH --height $HEIGHT \
            --framerate $FRAMERATE \
            --codec h264 \
            --bitrate $BITRATE \
            --intra $INTRA \
            --profile high \
            --inline \
            --denoise cdn_off \
            --awb auto \
            --output "$buffer_file" &
        
        local camera_pid=$!
        
        # Wait for file to be created and have content
        if ! wait_for_file "$buffer_file"; then
            kill $camera_pid 2>/dev/null
            return 1
        fi
        
        echo "Camera started successfully, starting ffmpeg..."
        
        # Start ffmpeg that reads from the buffer file
        ffmpeg -re -fflags +genpts -flags low_delay \
            -f h264 -r $FRAMERATE \
            -i "$buffer_file" \
            -stream_loop -1 -i audio.mp3 \
            -c:v copy \
            -c:a aac \
            -shortest \
            -g $INTRA \
            -f flv "${URL}/${KEY}" &
        
        local ffmpeg_pid=$!
    fi
    
    echo "$camera_pid $ffmpeg_pid $buffer_file"
    return 0
}

# Initialize sun times
get_sun_times
LAST_SUN_UPDATE=$(date +%s)

# Main loop
while true; do
    # Update sun times once per day (at midnight)
    current_date=$(date +%Y%m%d)
    last_update_date=$(date -d "@$LAST_SUN_UPDATE" +%Y%m%d)

    if [ "$current_date" != "$last_update_date" ]; then
        echo "New day detected, updating sun times..."
        get_sun_times
        LAST_SUN_UPDATE=$(date +%s)
    fi

    # Determine if nighttime
    if is_nighttime; then
        night_mode=0
        echo "It's nighttime - using nighttime settings"
    else
        night_mode=1
        echo "It's daytime - using daytime settings"
    fi

    # Start the stream pipeline
    echo "Starting new stream session..."
    result=$(create_stream_pipeline $night_mode)
    
    if [ $? -ne 0 ]; then
        echo "Failed to start stream pipeline, retrying in 10 seconds..."
        sleep 10
        continue
    fi
    
    camera_pid=$(echo $result | cut -d' ' -f1)
    ffmpeg_pid=$(echo $result | cut -d' ' -f2)
    buffer_file=$(echo $result | cut -d' ' -f3)
    
    echo "Stream started successfully!"
    echo "Camera PID: $camera_pid, FFmpeg PID: $ffmpeg_pid"
    
    # Wait 30 minutes then restart camera (but keep ffmpeg running)
    echo "Waiting 30 minutes before camera restart..."
    sleep 1800  # 30 minutes
    
    # Restart camera process only
    echo "Restarting camera process..."
    kill $camera_pid 2>/dev/null
    wait $camera_pid 2>/dev/null
    
    echo "Camera stopped, ffmpeg continues running..."
    
    # Small delay before next iteration (camera will be restarted)
    sleep 2
    
    # Clean up the buffer file for the next session
    rm -f "$buffer_file"
done
