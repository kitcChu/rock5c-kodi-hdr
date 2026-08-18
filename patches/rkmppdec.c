/*
 * RockChip MPP Video Decoder
 * Copyright (c) 2017 Lionel CHAZALLON
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include <drm_fourcc.h>
#include <pthread.h>
#include <rockchip/mpp_buffer.h>
#include <rockchip/rk_mpi.h>
#include <time.h>
#include <unistd.h>

#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include "hwconfig.h"
#include "libavutil/buffer.h"
#include "libavutil/common.h"
#include "libavutil/frame.h"
#include "libavutil/hwcontext.h"
#include "libavutil/hwcontext_drm.h"
#include "libavutil/imgutils.h"
#include "libavutil/log.h"
#include "libavutil/mastering_display_metadata.h"

#define RECEIVE_FRAME_TIMEOUT   100
#define FRAMEGROUP_MAX_FRAMES   16
#define INPUT_MAX_PACKETS       16

typedef struct {
    MppCtx ctx;
    MppApi *mpi;
    MppBufferGroup frame_group;

    char first_packet;
    char eos_reached;
    char eos_sent;

    AVPacket pending_pkt;

    AVMasteringDisplayMetadata mastering;
    AVContentLightMetadata cll;
    char have_mastering;
    char have_cll;

    int64_t last_fed_pts;

    AVBufferRef *frames_ref;
    AVBufferRef *device_ref;
} RKMPPDecoder;

typedef struct {
    AVClass *av_class;
    AVBufferRef *decoder_ref;
} RKMPPDecodeContext;

typedef struct {
    MppFrame frame;
    AVBufferRef *decoder_ref;
} RKMPPFrameContext;

static MppCodingType rkmpp_get_codingtype(AVCodecContext *avctx)
{
    switch (avctx->codec_id) {
    case AV_CODEC_ID_H264:          return MPP_VIDEO_CodingAVC;
    case AV_CODEC_ID_HEVC:          return MPP_VIDEO_CodingHEVC;
    case AV_CODEC_ID_VP8:           return MPP_VIDEO_CodingVP8;
    case AV_CODEC_ID_VP9:           return MPP_VIDEO_CodingVP9;
    default:                        return MPP_VIDEO_CodingUnused;
    }
}

static uint32_t rkmpp_get_frameformat(MppFrameFormat mppformat)
{
    /* strip HDR/compression flag bits (e.g. 0x04000001 for HDR 10-bit) */
    mppformat = (MppFrameFormat)(mppformat & MPP_FRAME_FMT_MASK);
    switch (mppformat) {
    case MPP_FMT_YUV420SP:          return DRM_FORMAT_NV12;
    /* RK3588 10-bit output is NV15 packed layout, scannable by Esmart planes */
    case MPP_FMT_YUV420SP_10BIT:    return DRM_FORMAT_NV15;
    default:                        return 0;
    }
}

static int rkmpp_write_data(AVCodecContext *avctx, uint8_t *buffer, int size, int64_t pts)
{
    RKMPPDecodeContext *rk_context = avctx->priv_data;
    RKMPPDecoder *decoder = (RKMPPDecoder *)rk_context->decoder_ref->data;
    int ret;
    MppPacket packet;

    // create the MPP packet
    ret = mpp_packet_init(&packet, buffer, size);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Failed to init MPP packet (code = %d)\n", ret);
        return AVERROR_UNKNOWN;
    }

    mpp_packet_set_pts(packet, pts);
    if (pts != AV_NOPTS_VALUE)
        ((RKMPPDecoder *)((RKMPPDecodeContext *)avctx->priv_data)->decoder_ref->data)->last_fed_pts = pts;

    if (!buffer)
        mpp_packet_set_eos(packet);

    ret = decoder->mpi->decode_put_packet(decoder->ctx, packet);
    if (ret != MPP_OK) {
        if (ret == MPP_ERR_BUFFER_FULL) {
            av_log(avctx, AV_LOG_DEBUG, "Buffer full writing %d bytes to decoder\n", size);
            ret = AVERROR(EAGAIN);
        } else
            ret = AVERROR_UNKNOWN;
    }
    else
        av_log(avctx, AV_LOG_DEBUG, "Wrote %d bytes to decoder\n", size);

    mpp_packet_deinit(&packet);

    return ret;
}

static int rkmpp_close_decoder(AVCodecContext *avctx)
{
    RKMPPDecodeContext *ctx0 = avctx->priv_data;
    if (ctx0->decoder_ref) {
        RKMPPDecoder *d = (RKMPPDecoder *)ctx0->decoder_ref->data;
        if (d)
            av_packet_unref(&d->pending_pkt);
    }

    RKMPPDecodeContext *rk_context = avctx->priv_data;
    av_buffer_unref(&rk_context->decoder_ref);
    return 0;
}

static void rkmpp_release_decoder(void *opaque, uint8_t *data)
{
    RKMPPDecoder *decoder = (RKMPPDecoder *)data;

    if (decoder->mpi) {
        decoder->mpi->reset(decoder->ctx);
        mpp_destroy(decoder->ctx);
        decoder->ctx = NULL;
    }

    if (decoder->frame_group) {
        mpp_buffer_group_put(decoder->frame_group);
        decoder->frame_group = NULL;
    }

    av_buffer_unref(&decoder->frames_ref);
    av_buffer_unref(&decoder->device_ref);

    av_free(decoder);
}

static int rkmpp_init_decoder(AVCodecContext *avctx)
{
    RKMPPDecodeContext *rk_context = avctx->priv_data;
    RKMPPDecoder *decoder = NULL;
    MppCodingType codectype = MPP_VIDEO_CodingUnused;
    int ret;
    RK_S64 paramS64;
    RK_S32 paramS32;

    avctx->pix_fmt = AV_PIX_FMT_DRM_PRIME;

    // create a decoder and a ref to it
    decoder = av_mallocz(sizeof(RKMPPDecoder));
    if (!decoder) {
        ret = AVERROR(ENOMEM);
        goto fail;
    }

    rk_context->decoder_ref = av_buffer_create((uint8_t *)decoder, sizeof(*decoder), rkmpp_release_decoder,
                                               NULL, AV_BUFFER_FLAG_READONLY);
    if (!rk_context->decoder_ref) {
        av_free(decoder);
        ret = AVERROR(ENOMEM);
        goto fail;
    }

    av_log(avctx, AV_LOG_DEBUG, "Initializing RKMPP decoder.\n");

    codectype = rkmpp_get_codingtype(avctx);
    if (codectype == MPP_VIDEO_CodingUnused) {
        av_log(avctx, AV_LOG_ERROR, "Unknown codec type (%d).\n", avctx->codec_id);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    ret = mpp_check_support_format(MPP_CTX_DEC, codectype);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Codec type (%d) unsupported by MPP\n", avctx->codec_id);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    // Create the MPP context
    ret = mpp_create(&decoder->ctx, &decoder->mpi);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Failed to create MPP context (code = %d).\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    // initialize mpp
    ret = mpp_init(decoder->ctx, MPP_CTX_DEC, codectype);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Failed to initialize MPP context (code = %d).\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    // make decode calls blocking with a timeout
    paramS64 = RECEIVE_FRAME_TIMEOUT;
    ret = decoder->mpi->control(decoder->ctx, MPP_SET_OUTPUT_TIMEOUT, &paramS64);
    if (ret != MPP_OK) {
        av_log(avctx, AV_LOG_ERROR, "Failed to set output timeout on MPI (code = %d).\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    // parser fast mode: emit tasks as soon as a frame is complete
    paramS32 = 1;
    decoder->mpi->control(decoder->ctx, MPP_DEC_SET_PARSER_FAST_MODE, &paramS32);

    // enable parser split mode: input packets may not be complete frames
    paramS32 = 1;
    ret = decoder->mpi->control(decoder->ctx, MPP_DEC_SET_PARSER_SPLIT_MODE, &paramS32);
    if (ret != MPP_OK)
        av_log(avctx, AV_LOG_WARNING, "Failed to enable parser split mode (code = %d).\n", ret);

    // do not abort decoding on hardware/reported stream errors (H.264/H.265)
    ret = decoder->mpi->control(decoder->ctx, MPP_DEC_SET_DISABLE_ERROR, NULL);
    if (ret != MPP_OK)
        av_log(avctx, AV_LOG_WARNING, "Failed to disable error reporting on MPI (code = %d).\n", ret);

    ret = mpp_buffer_group_get_internal(&decoder->frame_group, MPP_BUFFER_TYPE_ION);
    if (ret) {
       av_log(avctx, AV_LOG_ERROR, "Failed to retrieve buffer group (code = %d)\n", ret);
       ret = AVERROR_UNKNOWN;
       goto fail;
    }

    ret = decoder->mpi->control(decoder->ctx, MPP_DEC_SET_EXT_BUF_GROUP, decoder->frame_group);
    if (ret) {
        av_log(avctx, AV_LOG_ERROR, "Failed to assign buffer group (code = %d)\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    ret = mpp_buffer_group_limit_config(decoder->frame_group, 0, FRAMEGROUP_MAX_FRAMES);
    if (ret) {
        av_log(avctx, AV_LOG_ERROR, "Failed to set buffer group limit (code = %d)\n", ret);
        ret = AVERROR_UNKNOWN;
        goto fail;
    }

    decoder->first_packet = 1;
    av_init_packet(&decoder->pending_pkt);

    av_log(avctx, AV_LOG_DEBUG, "RKMPP decoder initialized successfully.\n");

    decoder->device_ref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_DRM);
    if (!decoder->device_ref) {
        ret = AVERROR(ENOMEM);
        goto fail;
    }
    ret = av_hwdevice_ctx_init(decoder->device_ref);
    if (ret < 0)
        goto fail;

    return 0;

fail:
    av_log(avctx, AV_LOG_ERROR, "Failed to initialize RKMPP decoder.\n");
    rkmpp_close_decoder(avctx);
    return ret;
}

static int rkmpp_send_packet(AVCodecContext *avctx, const AVPacket *avpkt)
{
    RKMPPDecodeContext *rk_context = avctx->priv_data;
    RKMPPDecoder *decoder = (RKMPPDecoder *)rk_context->decoder_ref->data;
    int ret;

    // handle EOF
    if (!avpkt->size) {
        av_log(avctx, AV_LOG_DEBUG, "End of stream.\n");
        decoder->eos_reached = 1;
        ret = rkmpp_write_data(avctx, NULL, 0, 0);
        if (ret)
            av_log(avctx, AV_LOG_ERROR, "Failed to send EOS to decoder (code = %d)\n", ret);
        return ret;
    }

    // on first packet, send extradata
    if (decoder->first_packet) {
        if (avctx->extradata_size) {
            ret = rkmpp_write_data(avctx, avctx->extradata,
                                            avctx->extradata_size,
                                            avpkt->pts);
            if (ret) {
                av_log(avctx, AV_LOG_ERROR, "Failed to write extradata to decoder (code = %d)\n", ret);
                return ret;
            }
        }
        decoder->first_packet = 0;
    }

    // now send packet
    ret = rkmpp_write_data(avctx, avpkt->data, avpkt->size, avpkt->pts);
    if (ret && ret!=AVERROR(EAGAIN))
        av_log(avctx, AV_LOG_ERROR, "Failed to write data to decoder (code = %d)\n", ret);

    return ret;
}

static void rkmpp_release_frame(void *opaque, uint8_t *data)
{
    AVDRMFrameDescriptor *desc = (AVDRMFrameDescriptor *)data;
    AVBufferRef *framecontextref = (AVBufferRef *)opaque;
    RKMPPFrameContext *framecontext = (RKMPPFrameContext *)framecontextref->data;

    mpp_frame_deinit(&framecontext->frame);
    av_buffer_unref(&framecontext->decoder_ref);
    av_buffer_unref(&framecontextref);

    av_free(desc);
}

static int rkmpp_retrieve_frame(AVCodecContext *avctx, AVFrame *frame)
{
    RKMPPDecodeContext *rk_context = avctx->priv_data;
    RKMPPDecoder *decoder = (RKMPPDecoder *)rk_context->decoder_ref->data;
    RKMPPFrameContext *framecontext = NULL;
    AVBufferRef *framecontextref = NULL;
    int ret;
    MppFrame mppframe = NULL;
    MppBuffer buffer = NULL;
    AVDRMFrameDescriptor *desc = NULL;
    AVDRMLayerDescriptor *layer = NULL;
    int mode;
    MppFrameFormat mppformat;
    uint32_t drmformat;

    ret = decoder->mpi->decode_get_frame(decoder->ctx, &mppframe);
    if (ret != MPP_OK && ret != MPP_ERR_TIMEOUT) {
        av_log(avctx, AV_LOG_ERROR, "Failed to get a frame from MPP (code = %d)\n", ret);
        goto fail;
    }

    if (mppframe) {
        // Check whether we have a special frame or not
        if (mpp_frame_get_info_change(mppframe)) {
            AVHWFramesContext *hwframes;

            av_log(avctx, AV_LOG_INFO, "Decoder noticed an info change (%dx%d), format=%d\n",
                                        (int)mpp_frame_get_width(mppframe), (int)mpp_frame_get_height(mppframe),
                                        (int)mpp_frame_get_fmt(mppframe));

            avctx->width = mpp_frame_get_width(mppframe);
            avctx->height = mpp_frame_get_height(mppframe);

            decoder->mpi->control(decoder->ctx, MPP_DEC_SET_INFO_CHANGE_READY, NULL);

            av_buffer_unref(&decoder->frames_ref);

            decoder->frames_ref = av_hwframe_ctx_alloc(decoder->device_ref);
            if (!decoder->frames_ref) {
                ret = AVERROR(ENOMEM);
                goto fail;
            }

            mppformat = mpp_frame_get_fmt(mppframe);
            drmformat = rkmpp_get_frameformat(mppformat);

            hwframes = (AVHWFramesContext*)decoder->frames_ref->data;
            hwframes->format    = AV_PIX_FMT_DRM_PRIME;
            hwframes->sw_format = drmformat == DRM_FORMAT_NV12 ? AV_PIX_FMT_NV12 : AV_PIX_FMT_NONE;
            hwframes->width     = avctx->width;
            hwframes->height    = avctx->height;
            ret = av_hwframe_ctx_init(decoder->frames_ref);
            if (ret < 0)
                goto fail;

            // here decoder is fully initialized, we need to feed it again with data
            ret = AVERROR(EAGAIN);
            goto fail;
        } else if (mpp_frame_get_eos(mppframe)) {
            av_log(avctx, AV_LOG_DEBUG, "Received a EOS frame.\n");
            decoder->eos_reached = 1;
            ret = AVERROR_EOF;
            goto fail;
        } else if (mpp_frame_get_discard(mppframe)) {
            av_log(avctx, AV_LOG_DEBUG, "Received a discard frame.\n");
            ret = AVERROR(EAGAIN);
            goto fail;
        } else if (mpp_frame_get_errinfo(mppframe)) {
            av_log(avctx, AV_LOG_ERROR, "Received a errinfo frame.\n");
            ret = AVERROR_UNKNOWN;
            goto fail;
        }

        // here we should have a valid frame
        av_log(avctx, AV_LOG_DEBUG, "Received a frame.\n");

        // setup general frame fields
        frame->format           = AV_PIX_FMT_DRM_PRIME;
        frame->width            = mpp_frame_get_width(mppframe);
        frame->height           = mpp_frame_get_height(mppframe);
        {
            int64_t mpp_pts = mpp_frame_get_pts(mppframe);
            if (mpp_pts < 0 || mpp_pts == AV_NOPTS_VALUE)
                mpp_pts = decoder->last_fed_pts;
            frame->pts = mpp_pts;
        }
        frame->color_range      = mpp_frame_get_color_range(mppframe);
        frame->color_primaries  = mpp_frame_get_color_primaries(mppframe);
        frame->color_trc        = mpp_frame_get_color_trc(mppframe);
        frame->colorspace       = mpp_frame_get_colorspace(mppframe);

        mode = mpp_frame_get_mode(mppframe);
        frame->interlaced_frame = ((mode & MPP_FRAME_FLAG_FIELD_ORDER_MASK) == MPP_FRAME_FLAG_DEINTERLACED);
        frame->top_field_first  = ((mode & MPP_FRAME_FLAG_FIELD_ORDER_MASK) == MPP_FRAME_FLAG_TOP_FIRST);

        mppformat = mpp_frame_get_fmt(mppframe);
        drmformat = rkmpp_get_frameformat(mppformat);

        // forward HDR10 metadata harvested from packet side data
        if (decoder->have_mastering) {
            AVFrameSideData *sd = av_frame_new_side_data(frame,
                    AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,
                    sizeof(AVMasteringDisplayMetadata));
            if (sd)
                memcpy(sd->data, &decoder->mastering, sizeof(AVMasteringDisplayMetadata));
        }
        if (decoder->have_cll) {
            AVFrameSideData *sd = av_frame_new_side_data(frame,
                    AV_FRAME_DATA_CONTENT_LIGHT_LEVEL,
                    sizeof(AVContentLightMetadata));
            if (sd)
                memcpy(sd->data, &decoder->cll, sizeof(AVContentLightMetadata));
        }

        // now setup the frame buffer info
        buffer = mpp_frame_get_buffer(mppframe);
        if (buffer) {
            desc = av_mallocz(sizeof(AVDRMFrameDescriptor));
            if (!desc) {
                ret = AVERROR(ENOMEM);
                goto fail;
            }

            desc->nb_objects = 1;
            desc->objects[0].fd = mpp_buffer_get_fd(buffer);
            desc->objects[0].size = mpp_buffer_get_size(buffer);

            desc->nb_layers = 1;
            layer = &desc->layers[0];
            layer->format = drmformat;
            layer->nb_planes = 2;

            layer->planes[0].object_index = 0;
            layer->planes[0].offset = 0;
            layer->planes[0].pitch = mpp_frame_get_hor_stride(mppframe);

            layer->planes[1].object_index = 0;
            layer->planes[1].offset = layer->planes[0].pitch * mpp_frame_get_ver_stride(mppframe);
            layer->planes[1].pitch = layer->planes[0].pitch;

            // we also allocate a struct in buf[0] that will allow to hold additionnal information
            // for releasing properly MPP frames and decoder
            framecontextref = av_buffer_allocz(sizeof(*framecontext));
            if (!framecontextref) {
                ret = AVERROR(ENOMEM);
                goto fail;
            }

            // MPP decoder needs to be closed only when all frames have been released.
            framecontext = (RKMPPFrameContext *)framecontextref->data;
            framecontext->decoder_ref = av_buffer_ref(rk_context->decoder_ref);
            framecontext->frame = mppframe;

            frame->data[0]  = (uint8_t *)desc;
            frame->buf[0]   = av_buffer_create((uint8_t *)desc, sizeof(*desc), rkmpp_release_frame,
                                               framecontextref, AV_BUFFER_FLAG_READONLY);

            if (!frame->buf[0]) {
                ret = AVERROR(ENOMEM);
                goto fail;
            }

            frame->hw_frames_ctx = av_buffer_ref(decoder->frames_ref);
            if (!frame->hw_frames_ctx) {
                av_frame_unref(frame);
                return AVERROR(ENOMEM);
            }

            return 0;
        } else {
            av_log(avctx, AV_LOG_ERROR, "Failed to retrieve the frame buffer, frame is dropped (code = %d)\n", ret);
            mpp_frame_deinit(&mppframe);
        }
    } else if (decoder->eos_reached) {
        return AVERROR_EOF;
    } else if (ret == MPP_ERR_TIMEOUT) {
        av_log(avctx, AV_LOG_DEBUG, "Timeout when trying to get a frame from MPP\n");
    }

    return AVERROR(EAGAIN);

fail:
    if (mppframe)
        mpp_frame_deinit(&mppframe);

    if (framecontext)
        av_buffer_unref(&framecontext->decoder_ref);

    if (framecontextref)
        av_buffer_unref(&framecontextref);

    if (desc)
        av_free(desc);

    return ret;
}

/* ---- minimal HEVC SEI harvesting (HDR10) ---- */
static int sei_read_byte(const uint8_t **pp, const uint8_t *end)
{
    return (*pp < end) ? *(*pp)++ : -1;
}

static uint16_t sei_read_u16(const uint8_t **pp, const uint8_t *end)
{
    if (end - *pp < 2)
        return 0;
    uint16_t v = ((*pp)[0] << 8) | (*pp)[1];
    *pp += 2;
    return v;
}

static uint32_t sei_read_u32(const uint8_t **pp, const uint8_t *end)
{
    uint32_t v = 0;
    for (int i = 0; i < 4 && *pp < end; i++)
        v = (v << 8) | *(*pp)++;
    return v;
}

/* parse one SEI payload header; return payload size or -1 */
static int sei_payload(const uint8_t **pp, const uint8_t *end, int *type)
{
    int t = 0, sz = 0, b;
    do { b = sei_read_byte(pp, end); if (b < 0) return -1; t += b; } while (b == 255);
    do { b = sei_read_byte(pp, end); if (b < 0) return -1; sz += b; } while (b == 255);
    *type = t;
    return sz;
}

static void rkmpp_parse_sei(RKMPPDecoder *decoder, const uint8_t *sei, int size)
{
    const uint8_t *p = sei, *end = sei + size;
    while (p < end) {
        int type, sz;
        sz = sei_payload(&p, end, &type);
        if (sz < 0 || end - p < sz)
            break;
        if (type == 137 && sz >= 24 && !decoder->have_mastering) {
            /* mastering display colour volume: 3 primaries + wp + min/max lum */
            static const int mapping[3] = {2, 0, 1}; /* HEVC g,b,r -> r,g,b */
            AVMasteringDisplayMetadata *m = &decoder->mastering;
            uint16_t prim[3][2];
            for (int i = 0; i < 3; i++) {
                prim[i][0] = sei_read_u16(&p, end);
                prim[i][1] = sei_read_u16(&p, end);
            }
            m->white_point[0] = av_make_q(sei_read_u16(&p, end), 50000);
            m->white_point[1] = av_make_q(sei_read_u16(&p, end), 50000);
            m->max_luminance = av_make_q(sei_read_u32(&p, end), 10000);
            m->min_luminance = av_make_q(sei_read_u32(&p, end), 10000);
            for (int i = 0; i < 3; i++) {
                int j = mapping[i];
                m->display_primaries[i][0] = av_make_q(prim[j][0], 50000);
                m->display_primaries[i][1] = av_make_q(prim[j][1], 50000);
            }
            m->has_primaries = 1;
            m->has_luminance = 1;
            decoder->have_mastering = 1;
        } else if (type == 144 && sz >= 4 && !decoder->have_cll) {
            decoder->cll.MaxCLL  = sei_read_u16(&p, end);
            decoder->cll.MaxFALL = sei_read_u16(&p, end);
            decoder->have_cll = 1;
        } else {
            p += sz; /* skip */
        }
    }
}

/* remove emulation prevention bytes (00 00 03 -> 00 00) in place */
static int rkmpp_strip_epb(uint8_t *dst, const uint8_t *src, int size)
{
    int di = 0, zeros = 0;
    for (int si = 0; si < size; si++) {
        if (zeros == 2 && src[si] == 3) {
            zeros = 0;          /* drop the 03 */
            continue;
        }
        zeros = (src[si] == 0) ? zeros + 1 : 0;
        dst[di++] = src[si];
    }
    return di;
}

static void rkmpp_sei_from_nal(RKMPPDecoder *decoder, const uint8_t *nal, int size)
{
    /* nal: full NAL including 2-byte header, already EPB-stripped */
    if (size < 3)
        return;
    int ntype = (nal[0] >> 1) & 0x3F;
    if (ntype == 39)  /* PREFIX_SEI: payload starts after 2-byte NAL hdr */
        rkmpp_parse_sei(decoder, nal + 2, size - 2);
}

/* scan one NAL (shared by both formats) using a small stack buffer */
static void rkmpp_scan_nal(RKMPPDecoder *decoder, const uint8_t *nal, int nal_size)
{
    uint8_t tmp[512];
    int n = rkmpp_strip_epb(tmp, nal, nal_size < 512 ? nal_size : 512);
    rkmpp_sei_from_nal(decoder, tmp, n);
}

/* scan a packet for SEI: supports hvcC length-prefixed AND Annex-B */
static void rkmpp_scan_sei(RKMPPDecoder *decoder, const uint8_t *data, int size)
{
    /* heuristic: hvcC if first 4 bytes are a plausible length */
    if (size > 8) {
        uint32_t len4 = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
        if (len4 > 0 && len4 + 4 <= size && data[4] >> 1 && !(data[0]==0 && data[1]==0 && data[2]<=1)) {
            const uint8_t *p = data, *end = data + size;
            while (p + 4 <= end) {
                uint32_t l = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
                if (l == 0 || p + 4 + l > end)
                    break;      /* malformed -> fall through to annexb */
                rkmpp_scan_nal(decoder, p + 4, l);
                p += 4 + l;
            }
            return;
        }
    }
    /* Annex-B start codes */
    const uint8_t *p = data, *end = data + size;
    while (p + 4 <= end) {
        if (p[0] == 0 && p[1] == 0 && p[2] == 1) {
            const uint8_t *nal = p + 3;
            const uint8_t *q = nal + 2;
            const uint8_t *next = end;
            while (q + 3 <= end) {
                if (q[0] == 0 && q[1] == 0 && q[2] == 1) { next = q; break; }
                q++;
            }
            rkmpp_scan_nal(decoder, nal, next - nal);
            p = next;
        } else {
            p++;
        }
    }
}

static void rkmpp_harvest_metadata(AVCodecContext *avctx, RKMPPDecoder *decoder,
                                   const AVPacket *pkt)
{
    if (decoder->have_mastering && decoder->have_cll)
        return;

    const AVPacketSideData *sd = NULL;
    int n = 0;

    /* stream-level side data (MKV Colour element) */
    if (avctx->coded_side_data) {
        sd = avctx->coded_side_data;
        n = avctx->nb_coded_side_data;
        for (int i = 0; i < n; i++) {
            if (sd[i].type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA &&
                sd[i].size >= (int)sizeof(AVMasteringDisplayMetadata) && !decoder->have_mastering) {
                memcpy(&decoder->mastering, sd[i].data, sizeof(AVMasteringDisplayMetadata));
                decoder->have_mastering = 1;
            }
            if (sd[i].type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL &&
                sd[i].size >= (int)sizeof(AVContentLightMetadata) && !decoder->have_cll) {
                memcpy(&decoder->cll, sd[i].data, sizeof(AVContentLightMetadata));
                decoder->have_cll = 1;
            }
        }
    }

    /* per-packet side data */
    if (pkt) {
        if ((!decoder->have_mastering || !decoder->have_cll) && pkt->data && pkt->size > 5)
            rkmpp_scan_sei(decoder, pkt->data, pkt->size);
        for (int i = 0; i < pkt->side_data_elems; i++) {
            if (pkt->side_data[i].type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA &&
                pkt->side_data[i].size >= (int)sizeof(AVMasteringDisplayMetadata) && !decoder->have_mastering) {
                memcpy(&decoder->mastering, pkt->side_data[i].data, sizeof(AVMasteringDisplayMetadata));
                decoder->have_mastering = 1;
            }
            if (pkt->side_data[i].type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL &&
                pkt->side_data[i].size >= (int)sizeof(AVContentLightMetadata) && !decoder->have_cll) {
                memcpy(&decoder->cll, pkt->side_data[i].data, sizeof(AVContentLightMetadata));
                decoder->have_cll = 1;
            }
        }
    }
}

static int rkmpp_receive_frame(AVCodecContext *avctx, AVFrame *frame)
{
    RKMPPDecodeContext *rk_context = avctx->priv_data;
    RKMPPDecoder *decoder = (RKMPPDecoder *)rk_context->decoder_ref->data;
    int ret = MPP_NOK;
    AVPacket pkt = {0};
    RK_S32 usedslots, freeslots;

    if (!decoder->eos_reached) {
        // greedily fill the decoder input queue: keep pulling packets from
        // the demuxer and pushing them until the decoder says it is full.
        // this keeps the hardware pipeline busy instead of serializing one
        // put with one frame retrieval per call.
        for (int i = 0; i < INPUT_MAX_PACKETS; i++) {
            if (!decoder->pending_pkt.data && !decoder->eos_sent) {
                ret = ff_decode_get_packet(avctx, &pkt);
                if (ret < 0 && ret != AVERROR_EOF) {
                    return ret;
                }
                if (ret == AVERROR_EOF) {
                    decoder->eos_sent = 1;
                } else {
                    ret = av_packet_ref(&decoder->pending_pkt, &pkt);
                    av_packet_unref(&pkt);
                    if (ret < 0)
                        return ret;
                }
            }

            if (decoder->pending_pkt.data) {
                rkmpp_harvest_metadata(avctx, decoder, &decoder->pending_pkt);
                ret = rkmpp_send_packet(avctx, &decoder->pending_pkt);
                if (ret == AVERROR(EAGAIN))
                    break; /* input queue full - retrieve frames below */
                av_packet_unref(&decoder->pending_pkt);
                if (ret < 0) {
                    av_log(avctx, AV_LOG_ERROR, "Failed to send packet to decoder (code = %d)\n", ret);
                    return ret;
                }
            } else if (decoder->eos_sent) {
                ret = rkmpp_send_packet(avctx, &(AVPacket){0});
                if (ret < 0) {
                    av_log(avctx, AV_LOG_ERROR, "Failed to send EOS to decoder (code = %d)\n", ret);
                    return ret;
                }
                break;
            } else {
                break;
            }
        }
    }

    return rkmpp_retrieve_frame(avctx, frame);
}

static void rkmpp_flush(AVCodecContext *avctx)
{
    RKMPPDecodeContext *rk_context = avctx->priv_data;
    RKMPPDecoder *decoder = (RKMPPDecoder *)rk_context->decoder_ref->data;
    int ret = MPP_NOK;

    av_log(avctx, AV_LOG_DEBUG, "Flush.\n");

    ret = decoder->mpi->reset(decoder->ctx);
    if (ret == MPP_OK) {
        decoder->first_packet = 1;
    } else
        av_log(avctx, AV_LOG_ERROR, "Failed to reset MPI (code = %d)\n", ret);

    /* reset wrapper state so post-seek feeding starts clean */
    av_packet_unref(&decoder->pending_pkt);
    decoder->eos_sent = 0;
    decoder->eos_reached = 0;
}

static const AVCodecHWConfigInternal *const rkmpp_hw_configs[] = {
    HW_CONFIG_INTERNAL(DRM_PRIME),
    NULL
};

#define RKMPP_DEC_CLASS(NAME) \
    static const AVClass rkmpp_##NAME##_dec_class = { \
        .class_name = "rkmpp_" #NAME "_dec", \
        .version    = LIBAVUTIL_VERSION_INT, \
    };

#define RKMPP_DEC(NAME, ID, BSFS) \
    RKMPP_DEC_CLASS(NAME) \
    const FFCodec ff_##NAME##_rkmpp_decoder = { \
        .p.name         = #NAME "_rkmpp", \
        .p.long_name    = NULL_IF_CONFIG_SMALL(#NAME " (rkmpp)"), \
        .p.type         = AVMEDIA_TYPE_VIDEO, \
        .p.id           = ID, \
        .priv_data_size = sizeof(RKMPPDecodeContext), \
        .init           = rkmpp_init_decoder, \
        .close          = rkmpp_close_decoder, \
        FF_CODEC_RECEIVE_FRAME_CB(rkmpp_receive_frame), \
        .flush          = rkmpp_flush, \
        .p.priv_class   = &rkmpp_##NAME##_dec_class, \
        .p.capabilities = AV_CODEC_CAP_DELAY | AV_CODEC_CAP_AVOID_PROBING | AV_CODEC_CAP_HARDWARE, \
        .p.pix_fmts     = (const enum AVPixelFormat[]) { AV_PIX_FMT_DRM_PRIME, \
                                                         AV_PIX_FMT_NONE}, \
        .hw_configs     = rkmpp_hw_configs, \
        .bsfs           = BSFS, \
        .p.wrapper_name = "rkmpp", \
    };

RKMPP_DEC(h264,  AV_CODEC_ID_H264,          "h264_mp4toannexb")
RKMPP_DEC(hevc,  AV_CODEC_ID_HEVC,          "hevc_mp4toannexb")
RKMPP_DEC(vp8,   AV_CODEC_ID_VP8,           NULL)
RKMPP_DEC(vp9,   AV_CODEC_ID_VP9,           NULL)
