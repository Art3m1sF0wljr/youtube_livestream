#!/bin/bash

# Stream configuration for Camera Module v1
WIDTH=1296
HEIGHT=972
FRAMERATE=30
BITRATE=20000000
INTRA=$((FRAMERATE * 2))

# Nighttime configuration
NIGHT_SHUTTER=2000000  # 2 seconds in microseconds
NIGHT_GAIN=16.0
NIGHT_FRAMERATE=1       # 1 fps input

# YouTube configuration
URL="rtmp://a.rtmp.youtube.com/live2"
KEY="" # Your YouTube stream key

# Location configuration (Rome, Italy)
LAT=41.54
LON=8.45
TIMEZONE="Europe/Rome"

# Buffer times (30 minutes = 0.5 hours in decimal)
DAYTIME_BUFFER=30  # minutes

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
    SUNRISE_TIME=$(date -d "$sunrise_local today - $DAYTIME_BUFFER minutes" +%H%M)
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

# Initialize sun times
get_sun_times
LAST_SUN_UPDATE=$(date +%s)

while true; do
    # Update sun times once per day (at midnight)
    current_date=$(date +%Y%m%d)
    last_update_date=$(date -d "@$LAST_SUN_UPDATE" +%Y%m%d)
    
    if [ "$current_date" != "$last_update_date" ]; then
        echo "New day detected, updating sun times..."
        get_sun_times
        LAST_SUN_UPDATE=$(date +%s)
    fi
    
    # Set a timeout for the stream (30 minutes)
    if is_nighttime; then
        echo "Using NIGHTTIME mode: long exposure (2s), high gain"
        echo "Daytime period: $SUNRISE_TIME to $SUNSET_TIME, Current: $(date +%H%M)"
        
        timeout 1800 bash -c "
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
                -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
                -c:v libx264 \
                -b:v $BITRATE \
                -r $FRAMERATE \
                -g $INTRA \
                -keyint_min $FRAMERATE \
                -preset fast \
                -tune zerolatency \
                -c:a aac \
                -shortest \
                -f flv '${URL}/${KEY}'
        "
    else
        echo "Using DAYTIME mode: normal exposure"
        echo "Daytime period: $SUNRISE_TIME to $SUNSET_TIME, Current: $(date +%H%M)"
        
        timeout 1800 bash -c "
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
                -f flv '${URL}/${KEY}'
        "
    fi

    # Stream ended (either crashed or timed out after 30 minutes)
    exit_code=$?
    if [ $exit_code -eq 124 ]; then
        echo "Stream timed out after 30 minutes, checking conditions again..."
    else
        echo "Stream crashed, restarting in 5 seconds..."
    fi
    sleep 5
done
