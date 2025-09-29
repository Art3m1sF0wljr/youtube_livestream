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

# Check interval for day/night transitions (2 minutes)
CHECK_INTERVAL=120

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

# Function to run stream with condition checking
run_stream_with_condition() {
    local mode=$1  # "day" or "night"
    local stream_pid=""
    
    while true; do
        # Update sun times once per day (at midnight)
        current_date=$(date +%Y%m%d)
        last_update_date=$(date -d "@$LAST_SUN_UPDATE" +%Y%m%d)

        if [ "$current_date" != "$last_update_date" ]; then
            echo "New day detected, updating sun times..."
            get_sun_times
            LAST_SUN_UPDATE=$(date +%s)
        fi
        
        # Check if we should still be in this mode
        if [ "$mode" = "night" ]; then
            if ! is_nighttime; then
                echo "Transition detected: night -> day"
                if [ -n "$stream_pid" ] && kill -0 "$stream_pid" 2>/dev/null; then
                    kill "$stream_pid"
                fi
                return 1
            fi
        else
            if is_nighttime; then
                echo "Transition detected: day -> night"
                if [ -n "$stream_pid" ] && kill -0 "$stream_pid" 2>/dev/null; then
                    kill "$stream_pid"
                fi
                return 1
            fi
        fi
        
        # If stream is not running, start it
        if [ -z "$stream_pid" ] || ! kill -0 "$stream_pid" 2>/dev/null; then
            echo "Starting $mode mode stream..."
            if [ "$mode" = "night" ]; then
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
                    --output - | \
                ffmpeg -f h264 -r $NIGHT_FRAMERATE -i - \
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
            else
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
                    --output - | \
                ffmpeg -f h264 -r $FRAMERATE -i - \
                    -stream_loop -1 -i audio.mp3 \
                    -c:v copy \
                    -c:a aac \
                    -shortest \
                    -g $INTRA \
                    -f flv "${URL}/${KEY}" &
            fi
            stream_pid=$!
            echo "Stream started with PID: $stream_pid"
        fi
        
        # Wait for check interval or until stream dies
        for ((i=0; i<CHECK_INTERVAL; i++)); do
            # Check if stream is still alive
            if [ -n "$stream_pid" ] && ! kill -0 "$stream_pid" 2>/dev/null; then
                echo "Stream process died, will restart..."
                stream_pid=""
                break
            fi
            sleep 1
        done
    done
}

# Initialize sun times
get_sun_times
LAST_SUN_UPDATE=$(date +%s)

# Main loop
while true; do
    if is_nighttime; then
        echo "Current mode: NIGHTTIME"
        echo "Daytime period: $SUNRISE_TIME to $SUNSET_TIME, Current: $(date +%H%M)"
        run_stream_with_condition "night"
    else
        echo "Current mode: DAYTIME" 
        echo "Daytime period: $SUNRISE_TIME to $SUNSET_TIME, Current: $(date +%H%M)"
        run_stream_with_condition "day"
    fi
    
    # Brief pause before switching modes to prevent rapid cycling
    #sleep 5
done
