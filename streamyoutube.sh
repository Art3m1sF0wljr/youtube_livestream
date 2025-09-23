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
LAT=5.14
LON=7.38
TIMEZONE="Europe/Rome"

# Function to get sunset and sunrise times from API
get_sun_times() {
    url="https://api.sunrise-sunset.org/json?lat=$LAT&lng=$LON&formatted=0"
    response=$(curl -s "$url")

    # Extract sunrise and sunset times (UTC)
    local sunrise_utc=$(echo "$response" | grep -o '"sunrise":"[^"]*' | cut -d'"' -f4)
    local sunset_utc=$(echo "$response" | grep -o '"sunset":"[^"]*' | cut -d'"' -f4)

    # Convert to local time (Rome time)
    SUNRISE_TIME=$(date -d "$sunrise_utc" +%H%M)
    SUNSET_TIME=$(date -d "$sunset_utc" +%H%M)

    echo "Today's sunrise: $SUNRISE_TIME, sunset: $SUNSET_TIME (Rome time)"
}

# Function to check if it's nighttime
is_nighttime() {
    local current_time=$(date +%H%M)

    # If current time is after sunset OR before sunrise, it's nighttime
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
    local current_date=$(date +%Y%m%d)
    local last_update_date=$(date -d "@$LAST_SUN_UPDATE" +%Y%m%d)

    if [ "$current_date" != "$last_update_date" ]; then
        echo "New day detected, updating sun times..."
        get_sun_times
        LAST_SUN_UPDATE=$(date +%s)
    fi

    # Set a timeout for the stream (30 minutes)
    if is_nighttime; then
        echo "Using NIGHTTIME mode: long exposure (2s), high gain"
        echo "Sunset: $SUNSET_TIME, Sunrise: $SUNRISE_TIME, Current: $(date +%H%M)"

        timeout 1800 bash -c "
            libcamera-vid -n -t 0 \
                --width $WIDTH --height $HEIGHT \
                --framerate $NIGHT_FRAMERATE \
                --shutter $NIGHT_SHUTTER \
                --gain $NIGHT_GAIN \
                --codec h264 \
                --bitrate $BITRATE \
                --intra $((NIGHT_FRAMERATE * 2)) \
                --profile high \
                --inline \
                --denoise cdn_fast \
                --awb auto \
                --output - | \
            ffmpeg -f h264 -r $NIGHT_FRAMERATE -i - \
                -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
                -c:v libx264 \
                -b:v $BITRATE \
                -r $FRAMERATE \
                -g $INTRA \
                -keyint_min $FRAMERATE \
                -preset ultrafast \
                -tune zerolatency \
                -c:a aac \
                -shortest \
                -f flv '${URL}/${KEY}'
        "
    else
        echo "Using DAYTIME mode: normal exposure"
        echo "Sunset: $SUNSET_TIME, Sunrise: $SUNRISE_TIME, Current: $(date +%H%M)"

        timeout 1800 bash -c "
            libcamera-vid -n -t 0 \
                --width $WIDTH --height $HEIGHT \
                --framerate $FRAMERATE \
                --codec h264 \
                --bitrate $BITRATE \
                --intra $INTRA \
                --profile high \
                --inline \
                --denoise cdn_fast \
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
    echo "Stream session ended, checking conditions again in 5 seconds..."
    sleep 5
done
