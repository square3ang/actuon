#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    const uint8_t *chart;
    size_t chart_len;
    const uint8_t *replay;
    size_t replay_len;
    uint8_t format; /* 1 = BMS, 2 = PMS, 3 = BMSON */
} ActuonVerifyInput;

typedef struct {
    bool ok;
    uint8_t clear;
    uint8_t gauge_type;
    uint32_t ex_score;
    uint32_t max_combo;
    uint32_t miss;
    uint32_t total_notes;
    uint32_t counts[6];
    float gauge_value;
    uint64_t seed;
} ActuonResult;

/* 0 on success; -1 malformed replay, -2 malformed chart or one PMS parsing cuts notes from, -3 chart hash differs from the replay's. */
int32_t actuon_verify(const ActuonVerifyInput *input, ActuonResult *out);
typedef struct {
    char title[256]; /* UTF-8, NUL-terminated, cut short when longer */
    char artist[256];
} ActuonChartInfo;

/* 0 when the bytes parse as a chart with notes to play, and names it in info; otherwise -2. format as above. */
int32_t actuon_check_chart(const uint8_t *data, size_t len, uint8_t format, ActuonChartInfo *info);
void actuon_chart_hash(const uint8_t *data, size_t len, char sha256_hex[64], char md5_hex[32]);
