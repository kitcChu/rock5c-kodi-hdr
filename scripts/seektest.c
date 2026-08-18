// seektest.c — reproduce kodi's seek flow on hevc_rkmpp directly:
// open file, decode 20 frames from 60s, avcodec_flush_buffers(),
// seek to 300s, decode 20 frames, print every frame pts.
// Build: cc -o seektest seektest.c $(pkg-config --cflags --libs libavcodec libavformat libavutil) -I/usr/include/aarch64-linux-gnu
#include <stdio.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>

int main(int argc, char **argv) {
    const char *path = argv[1];
    avformat_network_init();
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) { printf("open fail\n"); return 1; }
    avformat_find_stream_info(fmt, NULL);
    int vi = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    AVStream *vs = fmt->streams[vi];
    const AVCodec *c = avcodec_find_decoder_by_name("hevc_rkmpp");
    if (!c) { printf("no rkmpp\n"); return 1; }
    AVCodecContext *ctx = avcodec_alloc_context3(c);
    avcodec_parameters_to_context(ctx, vs->codecpar);
    ctx->pix_fmt = AV_PIX_FMT_DRM_PRIME;
    if (avcodec_open2(ctx, c, NULL) < 0) { printf("open2 fail\n"); return 1; }

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frm = av_frame_alloc();
    int64_t target = 60 * AV_TIME_BASE;      // 60s in us
    av_seek_frame(fmt, -1, target, AVSEEK_FLAG_BACKWARD);
    int got = 0, bad = 0;
    // phase 1: decode 20
    while (got < 20 && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != vi) { av_packet_unref(pkt); continue; }
        if (avcodec_send_packet(ctx, pkt) < 0) { av_packet_unref(pkt); continue; }
        av_packet_unref(pkt);
        while (avcodec_receive_frame(ctx, frm) == 0) {
            double t = frm->pts * av_q2d(vs->time_base);
            printf("P1 frame pts=%lld (%.2fs)\n", (long long)frm->pts, t);
            av_frame_unref(frm); got++;
        }
    }
    printf("--- flush ---\n");
    avcodec_flush_buffers(ctx);
    // phase 2: seek 300s, decode 20
    av_seek_frame(fmt, -1, 300 * AV_TIME_BASE, AVSEEK_FLAG_BACKWARD);
    got = 0;
    while (got < 20) {
        int r = av_read_frame(fmt, pkt);
        if (r < 0) { printf("eof/error %d\n", r); break; }
        if (pkt->stream_index != vi) { av_packet_unref(pkt); continue; }
        avcodec_send_packet(ctx, pkt);
        av_packet_unref(pkt);
        while (avcodec_receive_frame(ctx, frm) == 0) {
            int64_t p = frm->pts;
            double t = p * av_q2d(vs->time_base);
            int isbad = (p < 0 || t > 400 || t < 250);
            printf("P2 frame pts=%lld (%.2fs)%s\n", (long long)p, t, isbad ? "  <== BAD" : "");
            if (isbad) bad++;
            av_frame_unref(frm); got++;
        }
    }
    printf("summary: bad=%d of %d\n", bad, got);
    return 0;
}
