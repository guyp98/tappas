#!/bin/bash
set -e

function init_variables() {
    print_help_if_needed $@
    script_dir=$(dirname $(realpath "$0"))
    source $script_dir/../../../../scripts/misc/checks_before_run.sh

    readonly RESOURCES_DIR="$TAPPAS_WORKSPACE/apps/gstreamer/x86/multistream_detection/resources"
    readonly POSTPROCESS_DIR="$TAPPAS_WORKSPACE/apps/gstreamer/x86/libs/"
    readonly POSTPROCESS_SO="$POSTPROCESS_DIR/libnew_yolo_post.so"
    readonly HEF_PATH="$RESOURCES_DIR/yolov5m.hef"

    num_of_src=8
    live_src=""
    additonal_parameters=""
    sources=""
    compositor_locations="sink_0::xpos=0 sink_0::ypos=0 sink_1::xpos=640 sink_1::ypos=0 sink_2::xpos=1280 sink_2::ypos=0 sink_3::xpos=1920 sink_3::ypos=0 sink_4::xpos=0 sink_4::ypos=640 sink_5::xpos=640 sink_5::ypos=640 sink_6::xpos=1280 sink_6::ypos=640 sink_7::xpos=1920 sink_7::ypos=640"
    print_gst_launch_only=false
    video_sink_element=$([ "$XV_SUPPORTED" = "true" ] && echo "xvimagesink" || echo "ximagesink")
}

function print_usage() {
    echo "Multistream Detection hailo - pipeline usage:"
    echo ""
    echo "Options:"
    echo "  --help                  Show this help"
    echo "  --show-fps              Printing fps"
    echo "  --set-live-source       Use the live source given (example: /dev/video2). this flag is optional. if it's in use, num_of_sources is limited to 4."
    echo "  --num-of-sources NUM    Setting number of sources to given input (default value is 8)"
    echo "  --print-gst-launch      Print the ready gst-launch command without running it"
    exit 0
}

function print_help_if_needed() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
        fi

        shift
    done
}

function parse_args() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
            exit 0
        elif [ "$1" = "--print-gst-launch" ]; then
            print_gst_launch_only=true
        elif [ "$1" = "--show-fps" ]; then
            echo "Printing fps"
            additonal_parameters="-v 2>&1 | grep hailo_display"
        elif [ "$1" = "--set-live-source" ]; then
            shift
            echo "Setting live_src to $1"
            live_src=$1
        elif [ "$1" = "--num-of-sources" ]; then
            shift
            echo "Setting number of sources to $1"
            num_of_src=$1
        else
            echo "Received invalid argument: $1. See expected arguments below:"
            print_usage
            exit 1
        fi
        shift
    done
}

function create_sources() {
    start_index=0
    identity=""
    if [ "$live_src" != "" ] && [ -e $live_src ]; then
        identity="identity single-segment=true sync=true !"
        sources+="v4l2src device=$live_src name=source_0 ! videoflip video-direction=horiz ! \
                queue name=hailo_preprocess_q_0 leaky=downstream max_size_buffers=5 max-size-bytes=0 max-size-time=0 ! \
                videoconvert ! videobox autocrop=true ! video/x-raw,width=640,height=640,pixel-aspect-ratio=1/1 ! \
                $identity fun.sink_0 sid.src_0 ! queue name=comp_q_0 \
                leaky=downstream max_size_buffers=30 max-size-bytes=0 max-size-time=0 ! comp.sink_0 "
        start_index=1
        if [ $num_of_src -gt 4 ]; then
            num_of_src=4
        fi
    fi

    for ((n = $start_index; n < $num_of_src; n++)); do
        sources+="uridecodebin3 uri=file://$RESOURCES_DIR/detection$n.mp4 \
                name=source_$n ! videorate ! video/x-raw,framerate=30/1 ! \
                queue name=hailo_preprocess_q_$n leaky=no max_size_buffers=5 max-size-bytes=0  \
                max-size-time=0 ! videoconvert ! videoscale method=0 add-borders=false ! \
                video/x-raw,width=640,height=640,pixel-aspect-ratio=1/1 ! $identity \
                fun.sink_$n sid.src_$n ! queue name=comp_q_$n leaky=downstream max_size_buffers=30 \
                max-size-bytes=0 max-size-time=0 ! comp.sink_$n "
    done
}

function main() {
    init_variables $@
    parse_args $@
    create_sources

    hailo_bus_id=$(hailortcli scan | awk '{ print $NF }' | tail -n 1)

    # Check if an adapter that are accessible through the X-Video extension is found
    if xvinfo | grep -q 'no adaptors present'; then
        echo "No XV adaptors found, using ximagesink instead"
        video_sink_element="ximagesink"
    fi

    pipeline="gst-launch-1.0 \
           funnel name=fun ! \
           queue name=hailo_pre_infer_q_0 leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
           hailonet  hef-path=$HEF_PATH device-id=$hailo_bus_id debug=False qos=false batch-size=1 is-active=true ! \
           queue name=hailo_postprocess0 leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
           hailofilter2 so-path=$POSTPROCESS_SO qos=false ! \
           queue name=hailo_draw0 leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
           hailooverlay ! \
           streamiddemux name=sid compositor name=comp start-time-selection=0 $compositor_locations ! \
           queue name=hailo_video_q_0 leaky=no max_size_buffers=30 max-size-bytes=0 max-size-time=0 ! \
           videoconvert ! queue name=hailo_display_q_0 leaky=no max_size_buffers=30 max-size-bytes=0 max-size-time=0 ! \
           fpsdisplaysink video-sink=$video_sink_element name=hailo_display sync=false text-overlay=false \
           $sources ${additonal_parameters}"

    echo ${pipeline}
    if [ "$print_gst_launch_only" = true ]; then
        exit 0
    fi

    echo "Running Pipeline..."
    eval "${pipeline}"

}

main $@