package com.unilitix.unilitix_flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.zip.GZIPInputStream;

import org.junit.Test;

public class PowerSignalsTest {
    private static final long NOW = 1_760_000_000_000L; // 2025-10-09T08:53:20Z
    private static final long HOUR = 60L * 60 * 1000;
    private static final PowerSignals.Config CFG =
            new PowerSignals.Config("key", "https://api.example", "1700000000000", "salt", "2.2.0");

    private static File tempLog() throws IOException {
        File dir = Files.createTempDirectory("power").toFile();
        return new File(dir, PowerSignals.FILE_NAME);
    }

    /** Records each request; answers with the scripted statuses in turn. */
    private static final class FakeTransport implements PowerSignals.Transport {
        final List<String> bodies = new ArrayList<>();
        final List<Map<String, String>> headers = new ArrayList<>();
        final List<String> urls = new ArrayList<>();
        final int[] statuses;

        FakeTransport(int... statuses) {
            this.statuses = statuses;
        }

        @Override
        public int post(String url, Map<String, String> h, byte[] body) {
            urls.add(url);
            headers.add(h);
            bodies.add(gunzip(body));
            int i = bodies.size() - 1;
            return i < statuses.length ? statuses[i] : 200;
        }
    }

    private static String gunzip(byte[] b) {
        try (GZIPInputStream in = new GZIPInputStream(new ByteArrayInputStream(b))) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new AssertionError(e);
        }
    }

    private static int count(String s, String needle) {
        int n = 0;
        for (int i = s.indexOf(needle); i >= 0; i = s.indexOf(needle, i + 1)) n++;
        return n;
    }

    @Test
    public void appendCapsTheLogAtFiveHundredLines() throws IOException {
        File f = tempLog();
        for (int i = 0; i < 520; i++) PowerSignals.append(f, "sample", NOW + i, i % 2 == 0);
        List<String> lines = PowerSignals.readLines(f);
        assertEquals(500, lines.size());
        assertEquals("sample," + (NOW + 20) + ",1", lines.get(0)); // the oldest 20 were dropped
    }

    @Test
    public void appendDropsADuplicateTransition() throws IOException {
        File f = tempLog();
        PowerSignals.append(f, "disconnect", NOW, null);
        PowerSignals.append(f, "disconnect", NOW + 500, null); // manifest + dynamic receiver
        PowerSignals.append(f, "connect", NOW + 600, null);
        PowerSignals.append(f, "disconnect", NOW + 5000, null);
        assertEquals(Arrays.asList("disconnect," + NOW, "connect," + (NOW + 600), "disconnect," + (NOW + 5000)),
                PowerSignals.readLines(f));
    }

    @Test
    public void parseRejectsMalformedLines() {
        assertNull(PowerSignals.parse("connect"));
        assertNull(PowerSignals.parse("connect,abc"));
        assertNull(PowerSignals.parse("connect,1,1"));
        assertNull(PowerSignals.parse("sample,1"));
        assertNull(PowerSignals.parse("sample,1,2"));
        assertNull(PowerSignals.parse("reboot,1"));
        assertEquals(Boolean.TRUE, PowerSignals.parse("sample,1,1").charging);
    }

    @Test
    public void batchesDropOldAndFutureEventsAndSplitAtTwoHundred() {
        List<String> lines = new ArrayList<>();
        lines.add("connect," + (NOW - 49 * HOUR)); // too old
        lines.add("connect," + (NOW + HOUR)); // clock skew
        for (int i = 450; i > 0; i--) lines.add("sample," + (NOW - i * 1000L) + ",0");
        List<List<PowerSignals.Event>> b = PowerSignals.batches(lines, NOW);
        assertEquals(3, b.size());
        assertEquals(200, b.get(0).size());
        assertEquals(200, b.get(1).size());
        assertEquals(50, b.get(2).size());
        assertEquals(NOW - 450_000L, b.get(0).get(0).tsMs); // oldest first
    }

    @Test
    public void bodyMatchesTheWireFormat() {
        List<PowerSignals.Event> events = Arrays.asList(
                PowerSignals.parse("disconnect,1760000000000"),
                PowerSignals.parse("sample,1760000060000,1"));
        assertEquals("{\"cell\":\"87589c984ffffff\",\"device\":\"abc\",\"events\":["
                + "{\"type\":\"disconnect\",\"ts\":\"2025-10-09T08:53:20.000Z\"},"
                + "{\"type\":\"sample\",\"charging\":true,\"ts\":\"2025-10-09T08:54:20.000Z\"}]}",
                PowerSignals.body("87589c984ffffff", "abc", events));
    }

    @Test
    public void deviceHashRotatesDailyAndHidesTheInstallId() {
        String a = PowerSignals.deviceHash("1700000000000", "salt", NOW);
        assertEquals(32, a.length());
        assertTrue(a.matches("[0-9a-f]{32}"));
        assertEquals(a, PowerSignals.deviceHash("1700000000000", "salt", NOW + HOUR));
        assertNotEquals(a, PowerSignals.deviceHash("1700000000000", "salt", NOW + 24 * HOUR));
        assertNotEquals(a, PowerSignals.deviceHash("1700000000000", "other", NOW));
        assertFalse(a.contains("1700000000000"));
        // Same vector as test/power_outage_test.dart (computed with Python hashlib).
        assertEquals("27042224245e18fcd6d8999c93dbef66", a);
    }

    @Test
    public void uploadSendsCellNotCoordinatesAndClearsTheLog() throws IOException {
        File f = tempLog();
        PowerSignals.append(f, "disconnect", NOW - HOUR, null);
        PowerSignals.append(f, "connect", NOW - 1000, null);
        FakeTransport t = new FakeTransport(202);
        assertEquals(PowerSignals.Outcome.SENT,
                PowerSignals.upload(f, CFG, 6.5244, 3.3792, NOW - HOUR, NOW, t));
        assertEquals(1, t.bodies.size());
        String body = t.bodies.get(0);
        assertTrue(body.startsWith("{\"cell\":\"87589c984ffffff\",\"device\":\""
                + PowerSignals.deviceHash("1700000000000", "salt", NOW) + "\""));
        assertFalse(body.contains("6.52"));
        assertFalse(body.contains("3.37"));
        assertEquals("https://api.example/v1/signals/power", t.urls.get(0));
        assertEquals("key", t.headers.get(0).get("x-unilitix-key"));
        assertEquals("gzip", t.headers.get(0).get("Content-Encoding"));
        assertTrue(PowerSignals.readLines(f).isEmpty());
    }

    @Test
    public void uploadSendsNothingWithoutAFreshLocation() throws IOException {
        File f = tempLog();
        PowerSignals.append(f, "disconnect", NOW - HOUR, null);
        FakeTransport t = new FakeTransport();
        assertEquals(PowerSignals.Outcome.NO_LOCATION, PowerSignals.upload(f, CFG, null, null, 0, NOW, t));
        assertEquals(PowerSignals.Outcome.NO_LOCATION,
                PowerSignals.upload(f, CFG, 6.5, 3.3, NOW - 25 * HOUR, NOW, t));
        assertTrue(t.bodies.isEmpty());
        assertEquals(1, PowerSignals.readLines(f).size()); // kept for a later attempt
    }

    @Test
    public void retryableFailureKeepsTheRestAndRejectionDrops() throws IOException {
        File f = tempLog();
        for (int i = 0; i < 450; i++) PowerSignals.append(f, "sample", NOW - 450_000L + i * 1000L, true);
        // First batch rejected (400: dropped), second 503 (kept, stop).
        FakeTransport t = new FakeTransport(400, 503);
        assertEquals(PowerSignals.Outcome.KEPT, PowerSignals.upload(f, CFG, 6.5, 3.3, NOW, NOW, t));
        assertEquals(2, t.bodies.size());
        assertEquals(200, count(t.bodies.get(0), "\"type\""));
        assertEquals(250, PowerSignals.readLines(f).size());
        // Auth failure keeps everything too.
        FakeTransport auth = new FakeTransport(401);
        assertEquals(PowerSignals.Outcome.KEPT, PowerSignals.upload(f, CFG, 6.5, 3.3, NOW, NOW, auth));
        assertEquals(250, PowerSignals.readLines(f).size());
        // Then everything goes.
        FakeTransport ok = new FakeTransport();
        assertEquals(PowerSignals.Outcome.SENT, PowerSignals.upload(f, CFG, 6.5, 3.3, NOW, NOW, ok));
        assertEquals(2, ok.bodies.size());
        assertTrue(PowerSignals.readLines(f).isEmpty());
    }

    @Test
    public void uploadPrunesEventsOlderThanFortyEightHours() throws IOException {
        File f = tempLog();
        PowerSignals.append(f, "connect", NOW - 50 * HOUR, null);
        FakeTransport t = new FakeTransport();
        assertEquals(PowerSignals.Outcome.EMPTY, PowerSignals.upload(f, CFG, 6.5, 3.3, NOW, NOW, t));
        assertTrue(t.bodies.isEmpty());
        assertFalse(f.exists());
    }

    @Test
    public void notConfiguredSendsNothing() throws IOException {
        File f = tempLog();
        PowerSignals.append(f, "connect", NOW, null);
        PowerSignals.Config missingSalt = new PowerSignals.Config("key", "https://a", "1", "", "2.2.0");
        assertEquals(PowerSignals.Outcome.NOT_CONFIGURED,
                PowerSignals.upload(f, missingSalt, 6.5, 3.3, NOW, NOW, new FakeTransport()));
    }
}
