package com.unilitix.unilitix_flutter;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.zip.GZIPOutputStream;

/**
 * Power-outage contribution: the on-device signal log and its upload to
 * {@code POST /v1/signals/power}.
 *
 * Pure Java with no Android APIs, so every rule here (cap, dedupe, 48 h
 * window, 200-event batches, daily device hash, request outcome handling) is
 * unit-testable on the JVM. The Android glue (receiver, worker, location,
 * preferences) lives in PowerContribution.kt and passes plain values in.
 *
 * Log format, one event per line: {@code type,epochMillis[,charging]} where
 * type is connect, disconnect or sample and charging (samples only) is 0 or 1.
 */
public final class PowerSignals {
    private PowerSignals() {}

    public static final String FILE_NAME = "unilitix_power_signals.log";
    static final int MAX_LINES = 500;
    static final int MAX_EVENTS_PER_REQUEST = 200;
    static final long MAX_EVENT_AGE_MS = 48L * 60 * 60 * 1000;
    /** Events stamped further in the future than this (bad clock) are dropped. */
    static final long MAX_CLOCK_SKEW_MS = 5L * 60 * 1000;
    /** A last-known location older than this is not used for a cell. */
    static final long MAX_LOCATION_AGE_MS = 24L * 60 * 60 * 1000;
    /** The same transition logged twice within this window is one event. */
    static final long DEDUPE_WINDOW_MS = 2000;
    static final int H3_RESOLUTION = 7;
    static final String PATH = "/v1/signals/power";

    /** Guards the log file: the receiver (main thread) and uploads (worker or plugin executor). */
    static final Object LOCK = new Object();

    // ── Log file ────────────────────────────────────────────────────────

    /** Appends one event, dropping a duplicate transition and keeping the last {@link #MAX_LINES}. */
    public static void append(File file, String type, long tsMs, Boolean charging) {
        String line = charging == null ? type + "," + tsMs : type + "," + tsMs + "," + (charging ? "1" : "0");
        synchronized (LOCK) {
            List<String> lines = readLines(file);
            if (!lines.isEmpty() && !"sample".equals(type)) {
                Event last = parse(lines.get(lines.size() - 1));
                if (last != null && last.type.equals(type) && Math.abs(last.tsMs - tsMs) < DEDUPE_WINDOW_MS) {
                    return;
                }
            }
            lines.add(line);
            if (lines.size() > MAX_LINES) {
                lines = new ArrayList<>(lines.subList(lines.size() - MAX_LINES, lines.size()));
            }
            writeLines(file, lines);
        }
    }

    static List<String> readLines(File file) {
        List<String> out = new ArrayList<>();
        if (file == null || !file.exists()) return out;
        try {
            byte[] bytes = readAll(file);
            String text = new String(bytes, StandardCharsets.UTF_8);
            for (String l : text.split("\n")) {
                String t = l.trim();
                if (!t.isEmpty()) out.add(t);
            }
        } catch (IOException e) {
            // Unreadable log: treat as empty; the next write replaces it.
        }
        return out;
    }

    /** Writes via a temp file and rename so a killed process never leaves half a log. */
    static void writeLines(File file, List<String> lines) {
        File tmp = new File(file.getPath() + ".tmp");
        StringBuilder sb = new StringBuilder();
        for (String l : lines) sb.append(l).append('\n');
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
            out.getFD().sync();
        } catch (IOException e) {
            tmp.delete();
            return;
        }
        if (!tmp.renameTo(file)) {
            file.delete();
            if (!tmp.renameTo(file)) tmp.delete();
        }
    }

    public static void clear(File file) {
        synchronized (LOCK) {
            if (file != null) {
                file.delete();
                new File(file.getPath() + ".tmp").delete();
            }
        }
    }

    /**
     * Removes the lines that were delivered (or permanently rejected), and
     * everything that is malformed or outside the 48 h window. Lines appended
     * while the upload was in flight are kept.
     */
    static void removeLines(File file, List<String> done, long nowMs) {
        synchronized (LOCK) {
            List<String> lines = readLines(file);
            Map<String, Integer> remaining = new HashMap<>();
            for (String d : done) {
                Integer n = remaining.get(d);
                remaining.put(d, n == null ? 1 : n + 1);
            }
            List<String> keep = new ArrayList<>();
            for (String l : lines) {
                Integer n = remaining.get(l);
                if (n != null && n > 0) {
                    remaining.put(l, n - 1);
                    continue;
                }
                if (isLive(parse(l), nowMs)) keep.add(l);
            }
            if (keep.size() != lines.size()) {
                if (keep.isEmpty()) {
                    file.delete();
                } else {
                    writeLines(file, keep);
                }
            }
        }
    }

    // ── Events ──────────────────────────────────────────────────────────

    static final class Event {
        final String type;
        final long tsMs;
        final Boolean charging;
        final String line;

        Event(String type, long tsMs, Boolean charging, String line) {
            this.type = type;
            this.tsMs = tsMs;
            this.charging = charging;
            this.line = line;
        }
    }

    static Event parse(String line) {
        if (line == null) return null;
        String[] p = line.split(",");
        if (p.length < 2) return null;
        String type = p[0];
        long ts;
        try {
            ts = Long.parseLong(p[1]);
        } catch (NumberFormatException e) {
            return null;
        }
        if ("connect".equals(type) || "disconnect".equals(type)) {
            return p.length == 2 ? new Event(type, ts, null, line) : null;
        }
        if ("sample".equals(type) && p.length == 3 && ("0".equals(p[2]) || "1".equals(p[2]))) {
            return new Event(type, ts, "1".equals(p[2]), line);
        }
        return null;
    }

    static boolean isLive(Event e, long nowMs) {
        return e != null && e.tsMs >= nowMs - MAX_EVENT_AGE_MS && e.tsMs <= nowMs + MAX_CLOCK_SKEW_MS;
    }

    /** Live events, oldest first, split into requests of at most {@link #MAX_EVENTS_PER_REQUEST}. */
    static List<List<Event>> batches(List<String> lines, long nowMs) {
        List<Event> live = new ArrayList<>();
        for (String l : lines) {
            Event e = parse(l);
            if (isLive(e, nowMs)) live.add(e);
        }
        Collections.sort(live, (a, b) -> Long.compare(a.tsMs, b.tsMs));
        List<List<Event>> out = new ArrayList<>();
        for (int i = 0; i < live.size(); i += MAX_EVENTS_PER_REQUEST) {
            out.add(new ArrayList<>(live.subList(i, Math.min(live.size(), i + MAX_EVENTS_PER_REQUEST))));
        }
        return out;
    }

    /** RFC 3339 UTC with milliseconds, identical to Dart's toIso8601String() for a UTC DateTime. */
    static String rfc3339(long ms) {
        SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f.format(new Date(ms));
    }

    static String utcDate(long ms) {
        SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd", Locale.US);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f.format(new Date(ms));
    }

    /**
     * The request's device id: the first 32 hex characters (128 bits) of
     * SHA-256("unilitix-power-v1|" + installId + "|" + salt + "|" + UTC date).
     * The salt is random, generated on the device and never sent, so the
     * server cannot recompute this from the install id it sees on sessions,
     * and ids from different days cannot be linked.
     */
    static String deviceHash(String installId, String salt, long nowMs) {
        String input = "unilitix-power-v1|" + installId + "|" + salt + "|" + utcDate(nowMs);
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(input.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 16; i++) sb.append(String.format(Locale.US, "%02x", d[i] & 0xff));
            return sb.toString();
        } catch (Exception e) {
            return null;
        }
    }

    /** The JSON body. Every value is generated here (hex, fixed words, timestamps), so no escaping is needed. */
    static String body(String cell, String device, List<Event> events) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"cell\":\"").append(cell).append("\",\"device\":\"").append(device).append("\",\"events\":[");
        for (int i = 0; i < events.size(); i++) {
            Event e = events.get(i);
            if (i > 0) sb.append(',');
            sb.append("{\"type\":\"").append(e.type).append('"');
            if (e.charging != null) sb.append(",\"charging\":").append(e.charging ? "true" : "false");
            sb.append(",\"ts\":\"").append(rfc3339(e.tsMs)).append("\"}");
        }
        sb.append("]}");
        return sb.toString();
    }

    // ── Upload ──────────────────────────────────────────────────────────

    public static final class Config {
        final String apiKey;
        final String apiUrl;
        final String installId;
        final String salt;
        final String sdkVersion;

        public Config(String apiKey, String apiUrl, String installId, String salt, String sdkVersion) {
            this.apiKey = apiKey;
            this.apiUrl = apiUrl;
            this.installId = installId;
            this.salt = salt;
            this.sdkVersion = sdkVersion;
        }

        boolean valid() {
            return notEmpty(apiKey) && notEmpty(apiUrl) && notEmpty(installId) && notEmpty(salt);
        }

        private static boolean notEmpty(String s) {
            return s != null && !s.isEmpty();
        }
    }

    /** One HTTP attempt; returns the status code, or -1 when no response arrived. */
    public interface Transport {
        int post(String url, Map<String, String> headers, byte[] body);
    }

    public enum Outcome {
        /** Nothing live to send. */
        EMPTY,
        /** No usable coarse location: nothing sent, events kept until they age out. */
        NO_LOCATION,
        /** Every batch delivered (or permanently rejected and dropped). */
        SENT,
        /** A batch failed in a retryable way (no response, 5xx, 429) or auth failed; the rest is kept. */
        KEPT,
        /** Not configured; nothing sent. */
        NOT_CONFIGURED,
    }

    /**
     * Uploads the log: prunes it, computes the res-7 cell from the given
     * coarse location (never sent itself), and posts batches oldest first,
     * one attempt each, stopping at the first failure that is worth retrying.
     *
     * @param locTimeMs when the location fix was taken; fixes older than
     *                  {@link #MAX_LOCATION_AGE_MS} are not used.
     */
    public static Outcome upload(File file, Config cfg, Double lat, Double lng, long locTimeMs, long nowMs,
                          Transport transport) {
        if (cfg == null || !cfg.valid()) return Outcome.NOT_CONFIGURED;
        List<String> lines;
        synchronized (LOCK) {
            lines = readLines(file);
        }
        removeLines(file, Collections.<String>emptyList(), nowMs); // prune stale lines
        List<List<Event>> batches = batches(lines, nowMs);
        if (batches.isEmpty()) return Outcome.EMPTY;

        if (lat == null || lng == null || nowMs - locTimeMs > MAX_LOCATION_AGE_MS) return Outcome.NO_LOCATION;
        String cell = PowerH3.latLngToCell(lat, lng, H3_RESOLUTION);
        String device = deviceHash(cfg.installId, cfg.salt, nowMs);
        if (cell == null || device == null) return Outcome.NO_LOCATION;

        Map<String, String> headers = new HashMap<>();
        headers.put("x-unilitix-key", cfg.apiKey);
        headers.put("User-Agent", "Unilitix-Flutter/" + cfg.sdkVersion);
        headers.put("Content-Type", "application/json");
        headers.put("Accept", "application/json");
        headers.put("Content-Encoding", "gzip");
        String url = cfg.apiUrl + PATH;

        for (List<Event> batch : batches) {
            int status;
            try {
                status = transport.post(url, headers, gzip(body(cell, device, batch)));
            } catch (RuntimeException e) {
                status = -1;
            }
            boolean ok = status >= 200 && status < 300;
            // 4xx other than 401/403/429: resending the same bytes can never succeed.
            boolean rejected = status >= 400 && status < 500 && status != 401 && status != 403 && status != 429;
            if (!ok && !rejected) return Outcome.KEPT;
            List<String> done = new ArrayList<>();
            for (Event e : batch) done.add(e.line);
            removeLines(file, done, nowMs);
        }
        return Outcome.SENT;
    }

    static byte[] gzip(String s) {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        try (GZIPOutputStream gz = new GZIPOutputStream(bos)) {
            gz.write(s.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
        return bos.toByteArray();
    }

    private static byte[] readAll(File file) throws IOException {
        try (InputStream in = new java.io.FileInputStream(file)) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        }
    }

    /** HttpURLConnection transport with the SDK's request timeout (40 s). */
    public static final class HttpTransport implements Transport {
        private static final int TIMEOUT_MS = 40_000;

        @Override
        public int post(String url, Map<String, String> headers, byte[] body) {
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(url).openConnection();
                c.setRequestMethod("POST");
                c.setConnectTimeout(TIMEOUT_MS);
                c.setReadTimeout(TIMEOUT_MS);
                c.setDoOutput(true);
                c.setUseCaches(false);
                c.setFixedLengthStreamingMode(body.length);
                for (Map.Entry<String, String> h : headers.entrySet()) c.setRequestProperty(h.getKey(), h.getValue());
                try (OutputStream out = c.getOutputStream()) {
                    out.write(body);
                }
                int status = c.getResponseCode();
                // Drain so the connection can be reused; the body is not needed.
                try (InputStream in = status < 400 ? c.getInputStream() : c.getErrorStream()) {
                    if (in != null) {
                        byte[] buf = new byte[1024];
                        while (in.read(buf) > 0) { /* discard */ }
                    }
                } catch (IOException ignored) {
                    // The status is what matters.
                }
                return status;
            } catch (IOException | RuntimeException e) {
                return -1;
            } finally {
                if (c != null) c.disconnect();
            }
        }
    }
}
