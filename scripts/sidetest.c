// sidetest.c — mimic kodi's DVDDemuxFFmpeg: open mkv, check
// av_stream_get_side_data(MASTERING) on the video stream.
#include <stdio.h>
#include <libavformat/avformat.h>

int main(int argc, char **argv) {
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0) { printf("open fail\n"); return 1; }
    avformat_find_stream_info(fmt, NULL);
    int vi = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    AVStream *st = fmt->streams[vi];
    int size = 0;
    uint8_t *sd = av_stream_get_side_data(st, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, &size);
    printf("mastering side data: %p size %d\n", (void*)sd, size);
    if (sd && size >= 24) {
        /* AVMasteringDisplayMetadata: 3 primaries[2] + white[2] (AVRational=8B) + min/max lum */
        printf("  (raw first 24 bytes present)\n");
    }
    sd = av_stream_get_side_data(st, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, &size);
    printf("cll side data: %p size %d\n", (void*)sd, size);
    printf("st->nb_side_data=%d\n", st->nb_side_data);
    for (int i = 0; i < st->nb_side_data; i++)
        printf("  side_data[%d] type=%d size=%d\n", i, st->side_data[i].type, st->side_data[i].size);
    return 0;
}
