#!/bin/bash

csvFile=""
downloader=""
processNumber=5
musicPath="./"
additionalKeywords=""

###
# Set operation variables
if [ -z "$1" ]; then
    echo "ERROR: No .csv file provided. Obtain one here: https://watsonbox.github.io/exportify/"
    exit 1
else
    csvFile=$1
fi

while [ $# -gt 0 ]; do
   if [[ $1 == *"--"* ]]; then
        param="${1/--/}"
        declare "$param"="$2"
   fi
   shift
done

if [[ -n $musicPath ]] && [[ ! -d "$musicPath" ]]
then
    echo "ERROR: Selected path does not exist: $musicPath"
    exit 1
fi
###

###
# Detect downloader and FFMPEG
if [[ -z "$downloader" ]]
then
    if command -v yt-dlp &> /dev/null
    then
        downloader="yt-dlp"
    elif command -v youtube-dl &> /dev/null
    then
        downloader="youtube-dl"
    else
        echo "No downloader provided or detected. Install 'yt-dlp' or 'youtube-dl'."
        exit 1
    fi
fi
echo "Using '$downloader' as downloader."

if ! command -v "ffmpeg" &> /dev/null
then
    echo "ERROR: FFMPEG could not be found. Install 'FFMPEG'."
    exit 1
fi
###

###
# Name of the different columns containing the metadata
colNameTitle="Track Name"
colNameArtist="Artist Name"
colNameImageURL="Album Image URL"
colNameAlbumName="Album Name"
colNameAlbumArtistName="Album Artist Name(s)"
colNameDiscNum="Disc Number"
colNameTrackNumber="Track Number"
colNamePopularity="Popularity"
colNameAlbumReleaseDate="Album Release Date"
colNameDuration="Track Duration (ms)"
###

csvHeader=$(head -1 "$csvFile" | tr ',' '\n' | nl)

###
# Evaluate the coresponding column number for each name
colNumTitle=$(echo "$csvHeader" | grep -w "$colNameTitle" | tr -d " " | awk -F " " '{print $1}')
colNumArtist=$(echo "$csvHeader" | grep -w "$colNameArtist" | tr -d " " | awk -F " " '{print $1}' | head -1)
colNumAlbumName=$(echo "$csvHeader"  | grep -w "$colNameAlbumName" | tr -d " " | awk -F " " '{print $1}')
colNumAlbumArtistName=$(echo "$csvHeader" | grep -w "$colNameAlbumArtistName" | tr -d " " | awk -F " " '{print $1}')
colNumAlbumReleaseDate=$(echo "$csvHeader" | grep -w "$colNameAlbumReleaseDate" | tr -d " " | awk -F " " '{print $1}')
colNumImageURL=$(echo "$csvHeader" | grep -w "$colNameImageURL" | tr -d " " | awk -F " " '{print $1}')
colNumDiscNumber=$(echo "$csvHeader" | grep -w "$colNameDiscNum" | tr -d " " | awk -F " " '{print $1}')
colNumTrack=$(echo "$csvHeader" | grep -w "$colNameTrackNumber" | tr -d " " | awk -F " " '{print $1}')
colNumDuration=$(echo "$csvHeader" | grep -w "$colNameDuration" | tr -d " " | awk -F " " '{print $1}')
colNumPopularity=$(echo "$csvHeader" | grep -w "$colNamePopularity" | tr -d " " | awk -F " " '{print $1}')
###

###
# Declare functions

# Function to get lyrics
downloadLrc() {
    # Input parameters
    track_name="$1"
    artist_name="$2"
    album_name="$3"
    duration_ms="$4"

    # Convert duration from milliseconds to seconds (integer division)
    duration=$((duration_ms / 1000))

    # URL encode the input parameters (if needed)
    encoded_track_name=$(echo "$track_name" | jq -sRr @uri)
    encoded_artist_name=$(echo "$artist_name" | jq -sRr @uri)
    encoded_album_name=$(echo "$album_name" | jq -sRr @uri)

    # API URL
    url="https://lrclib.net/api/get?track_name=${encoded_track_name}&artist_name=${encoded_artist_name}&album_name=${encoded_album_name}&duration=${duration}"

    # Request the lyrics from the API
    response=$(curl -A "SDB v0.0.1 (https://github.com/Daenges/Spotify-Downloader-Bash)" -s -w "%{http_code}" "$url")

    # Check the HTTP status code
    http_code="${response: -3}"
    response_body="${response:0:${#response}-3}"

    if [[ "$http_code" -eq 200 ]]; then
        # Extract synchronized lyrics or fallback to plain lyrics
        synced_lyrics=$(jq -r '.syncedLyrics // empty' <<< "$response_body")

        # If synced lyrics exist, output them; otherwise, fallback to plain lyrics
        if [[ -n "$synced_lyrics" ]]; then
            echo "$synced_lyrics" > "/tmp/${track_name}.lrc"
        else
            plain_lyrics=$(jq -r '.plainLyrics' <<< "$response_body")
            echo "$plain_lyrics" > "/tmp/${track_name}.lrc"
        fi
    fi
}

# Escape special characters for urls: https://gist.github.com/cdown/1163649
urlencode() {
    # urlencode <string>

    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C

    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:$i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done

    LC_COLLATE=$old_lc_collate
}

# Get rid of possible old cache
clearCache() {
    if [[ -f "/tmp/$1.mp3" ]]; then
        rm "/tmp/$1.mp3"
    fi

    if [[ -f "/tmp/$1.jpg" ]]; then
        rm "/tmp/$1.jpg"
    fi

    if [[ -f "/tmp/$1.lrc" ]]; then
        rm "/tmp/$1.lrc"
    fi
}
###

###
# Save all lines in array
songArray=()
###

###
# Populate array from file
while read -r songLine
do
    songArray+=("$songLine")
done < <(tail -n +2 "$csvFile")
echo "Found: ${#songArray[@]} entries"
###

###
# Get a line from .csv file as input - download and merge everything
crawlerTask() {
    ###
    # Split column names to array
    colArray=($(echo "$1" | sed 's/\"\"/\"_\"/g' | grep -Eo '"([^"]*)"' | sed 's/\"//g' | tr ' ' '_'))
    ###

    ###
    # Assert values for this entry to variables
    # Special replacement for songTitle as it is used for paths
    songTitle="$(echo "${colArray[$colNumTitle - 1]}" | tr '_/\\' ' ')"
    artist="$(echo "${colArray[$colNumArtist - 1]}" | tr '_' ' ' | cut -f1 -d',')"
    albumName="$(echo "${colArray[$colNumAlbumName - 1]}" | tr '_' ' ')"
    albumArtistsName="$(echo "${colArray[$colNumAlbumArtistName - 1]}" | tr '_' ' ')"
    albumReleaseDate="$(echo "${colArray[$colNumAlbumReleaseDate - 1]}" | tr '_' ' ')"
    image="$(echo "${colArray[$colNumImageURL - 1]}" | tr '_' ' ')"
    discNumber="$(echo "${colArray[$colNumDiscNumber - 1]}" | tr '_' ' ')"
    trackNumber="$(echo "${colArray[$colNumTrack - 1]}" | tr '_' ' ')"
    trackDuration="$(echo "${colArray[$colNumDuration - 1]}" | tr '_' ' ')"
    popularityScore="$(echo "${colArray[$colNumPopularity - 1]}" | tr '_' ' ')"
    ###

    # Remove possible old cache
    clearCache "$songTitle"

    ###
    # Prevent download if file already exists
    if [[ ! -f "${musicPath}${songTitle}.mp3" ]]; then

        # HTML escape all data
        songURL="https://music.youtube.com/search?q=$(urlencode "$songTitle")+$(urlencode "$artist")+$(urlencode "$additionalKeywords")#Songs"

        ###
        # Get cover and .mp3 file
        curl -s "$image" > "/tmp/${songTitle}.jpg" &
        $downloader -o "/tmp/${songTitle}.%(ext)s" "$songURL" -I 1 -x --audio-format mp3 --audio-quality 0 --quiet &
        wait
        ###

        ### Imbed Metadata
        if command -v eyeD3 &> /dev/null && command -v jq &> /dev/null; then
            # Get the Lyrics from https://lrclib.net/
            downloadLrc "${songTitle}" \
                        "${albumArtistsName}" \
                        "${albumName}" \
                        "${trackDuration}"

            # Use eyeD3
            eyeD3 --v2 \
            --title "${songTitle}" \
            --artist "${albumArtistsName}" \
            --album "${albumName}" \
            --release-date "${albumReleaseDate}" \
            --disc-num "${discNumber}" \
            --track "${trackNumber}" \
            --add-popularity "support@spotify.com:${popularityScore}" \
            "/tmp/${songTitle}.mp3" # &> /dev/null

            if [[ -f "/tmp/${songTitle}.lrc" ]]; then
                eyeD3 --v2 --add-lyrics "/tmp/${songTitle}.lrc" "/tmp/${songTitle}.mp3" # &> /dev/null
            fi

            if [[ -f "/tmp/${songTitle}.jpg" ]]; then
                eyeD3 --v2 --add-image "/tmp/${songTitle}.jpg:FRONT_COVER" "/tmp/${songTitle}.mp3" # &> /dev/null
            fi

            mv "/tmp/${songTitle}.mp3" "${musicPath}${songTitle}.mp3"
        else
            ###
            # Merge cover, metadata and .mp3 file
            ffmpeg -i "/tmp/${songTitle}.mp3" -i "/tmp/$songTitle.jpg" \
            -map 0:0 -map 1:0 -codec copy -id3v2_version 3 -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
            -metadata artist="$artist" \
            -metadata album="$albumName" \
            -metadata album_artist="$albumArtistsName" \
            -metadata disc="$discNumber" \
            -metadata title="$songTitle" \
            -metadata track="$trackNumber" \
            -hide_banner \
            -loglevel error \
            "${musicPath}${songTitle}.mp3" -y
            ###
        fi

        ###
        # Clear cached files
        clearCache "$songTitle"
        ###

        echo "Finished: ${songTitle}"
    else
        echo "Skipping: ${songTitle}.mp3 - (File already exists in: ${musicPath})"
    fi
    ###
}

###
startedSongs=0
numJobs="\j" # Number of background jobs.
###

###
# Start parallel crawling instances
for song in "${songArray[@]}"
do
    while (( ${numJobs@P} >= processNumber )); do
        wait -n
    done

    if [ -n "$song" ]; then
        crawlerTask "$song" &
    fi

    ((startedSongs++))
    echo "Status: #${startedSongs} downloads started - $(awk "BEGIN {print ((${startedSongs}/${#songArray[@]})*100)}")%"
done

echo "All downloads have been started. Waiting for completion."
wait $(jobs -p)
###

exit 0
