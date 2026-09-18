#!/usr/bin/env python3
"""Сшивает два транскрипта (собеседники и микрофон) в один диалог по времени.

Использование:
    merge_tracks.py others.srt me.srt transcript.txt

Зачем: запись встречи ведётся двумя дорожками — системный звук (собеседники) и
микрофон (я). Если свести их в один файл до распознавания, речь накладывается
друг на друга, качество падает, и в тексте невозможно понять, кто что сказал.
Распознаём дорожки по отдельности, а здесь расставляем по времени и подписываем.

Микрофон почти всегда слышит и колонки тоже (если человек без наушников), поэтому
реплики собеседников дублируются в дорожке микрофона. Такие дубли убираем:
если фраза с микрофона пересекается по времени с похожей фразой из системного
звука, оставляем версию из системного звука — она чище.
"""

import re
import sys
from difflib import SequenceMatcher

ME = "Я"
OTHERS = "Собеседники"

# Насколько похожими должны быть фразы, чтобы считать их одной и той же.
SIMILARITY_THRESHOLD = 0.72
# Максимальный разрыв между репликами одного человека, которые склеиваем в абзац.
MERGE_GAP_SECONDS = 2.0

TIME_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})"
)


def parse_srt(path, speaker):
    """Возвращает список сегментов [(начало, конец, кто, текст)] в секундах."""
    try:
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
    except FileNotFoundError:
        return []

    segments = []
    start = end = None
    lines = []

    def flush():
        if start is None:
            return
        text = " ".join(lines).strip()
        if text:
            segments.append((start, end, speaker, text))

    for line in raw.splitlines():
        match = TIME_RE.search(line)
        if match:
            flush()
            h1, m1, s1, ms1, h2, m2, s2, ms2 = (int(v) for v in match.groups())
            start = h1 * 3600 + m1 * 60 + s1 + ms1 / 1000
            end = h2 * 3600 + m2 * 60 + s2 + ms2 / 1000
            lines = []
        elif line.strip().isdigit() and not lines:
            continue
        elif line.strip():
            lines.append(line.strip())
        else:
            flush()
            start = end = None
            lines = []

    flush()
    return segments


def normalize(text):
    return re.sub(r"[^\w\s]", "", text.lower()).strip()


def drop_bleed(mic_segments, other_segments):
    """Убирает из дорожки микрофона то, что на самом деле звучало из колонок."""
    cleaned = []
    for start, end, speaker, text in mic_segments:
        norm = normalize(text)
        if not norm:
            continue
        duplicate = False
        for o_start, o_end, _, o_text in other_segments:
            if o_end < start - 2 or o_start > end + 2:
                continue
            if SequenceMatcher(None, norm, normalize(o_text)).ratio() >= SIMILARITY_THRESHOLD:
                duplicate = True
                break
        if not duplicate:
            cleaned.append((start, end, speaker, text))
    return cleaned


def format_time(seconds):
    total = int(seconds)
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def main():
    if len(sys.argv) < 4:
        print("Использование: merge_tracks.py <others.srt> <me.srt> <transcript.txt>")
        return 1

    others_path, mic_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    others = parse_srt(others_path, OTHERS)
    mine = drop_bleed(parse_srt(mic_path, ME), others)

    segments = sorted(others + mine, key=lambda item: item[0])
    if not segments:
        # Тот же случай, что и пустой транскрипт одной дорожки: речи в записи
        # нет. Отдельный код возврата, чтобы приложение объяснило это словами.
        print("В записи не нашлось речи — ни на одной дорожке.")
        return 3

    # Склеиваем подряд идущие реплики одного человека в абзац: иначе текст
    # рассыпается на сотни строк по 3-5 слов и читается тяжело.
    paragraphs = []
    for start, end, speaker, text in segments:
        if paragraphs:
            last = paragraphs[-1]
            if last["speaker"] == speaker and start - last["end"] <= MERGE_GAP_SECONDS:
                last["text"] += " " + text
                last["end"] = max(last["end"], end)
                continue
        paragraphs.append({"start": start, "end": end, "speaker": speaker, "text": text})

    with open(out_path, "w", encoding="utf-8") as out:
        for item in paragraphs:
            out.write(f"[{format_time(item['start'])}] {item['speaker']}: {item['text'].strip()}\n")

    mine_count = sum(1 for p in paragraphs if p["speaker"] == ME)
    print(f"Реплик: мои — {mine_count}, собеседников — {len(paragraphs) - mine_count}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
