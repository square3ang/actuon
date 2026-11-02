//! Difficulty tables in the bmstable format: an HTML page with a meta tag pointing at a
//! header JSON, which points at a data JSON. Courses come from the header's "course" field.
const std = @import("std");
const core = @import("actuon_core");
const http = @import("../platform/http.zig");
const db_mod = @import("../db/db.zig");
const Db = db_mod.Db;
const J = std.json.Value;

/// Value of `<meta name="bmstable" content="...">`, tolerant of attribute order and quoting.
pub fn findMeta(html: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.ascii.findIgnoreCase(html[pos..], "<meta")) |off| {
        const start = pos + off;
        const end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return null;
        pos = end;
        const tag = html[start..end];
        if (std.ascii.findIgnoreCase(tag, "bmstable") == null) continue;
        if (std.ascii.findIgnoreCase(tag, "name") == null) continue;
        const c_at = std.ascii.findIgnoreCase(tag, "content") orelse continue;
        const eq = std.mem.indexOfScalarPos(u8, tag, c_at, '=') orelse continue;
        var i = eq + 1;
        while (i < tag.len and tag[i] == ' ') i += 1;
        if (i >= tag.len) continue;
        const q = tag[i];
        if (q == '"' or q == '\'') {
            const close = std.mem.indexOfScalarPos(u8, tag, i + 1, q) orelse continue;
            return tag[i + 1 .. close];
        }
        const close = std.mem.indexOfAnyPos(u8, tag, i, " /") orelse tag.len;
        return tag[i..close];
    }
    return null;
}

/// Table JSON is UTF-8 by spec, but older tables are served as Shift-JIS.
fn parseJson(a: std.mem.Allocator, bytes_in: []const u8) !J {
    var bytes = bytes_in;
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes = bytes[3..];
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        bytes = try core.encoding.toUtf8(a, bytes, core.encoding.detect(bytes));
    }
    return std.json.parseFromSliceLeaky(J, a, bytes, .{ .allocate = .alloc_always });
}

fn str(v: ?J) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}

/// Levels may be strings or numbers in the wild.
fn levelStr(a: std.mem.Allocator, v: ?J) ![]const u8 {
    const x = v orelse return "";
    return switch (x) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
        else => "",
    };
}

fn levelLess(_: void, l: []const u8, r: []const u8) bool {
    const ln = std.fmt.parseFloat(f64, l) catch null;
    const rn = std.fmt.parseFloat(f64, r) catch null;
    if (ln != null and rn != null) return ln.? < rn.?;
    if (ln != null) return true;
    if (rn != null) return false;
    return std.mem.lessThan(u8, l, r);
}

fn hashList(a: std.mem.Allocator, course: std.json.ObjectMap) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(o: *std.ArrayList(u8), al: std.mem.Allocator, kind: u8, h: []const u8) !void {
            if (h.len == 0) return;
            if (o.items.len > 0) try o.append(al, ',');
            try o.append(al, kind);
            try o.append(al, ':');
            try o.appendSlice(al, h);
        }
    }.f;
    if (course.get("md5")) |m| if (m == .array) for (m.array.items) |h| try add(&out, a, 'm', str(h));
    if (course.get("sha256")) |m| if (m == .array) for (m.array.items) |h| try add(&out, a, 's', str(h));
    if (course.get("charts")) |m| if (m == .array) for (m.array.items) |ch| {
        if (ch != .object) continue;
        const sha = str(ch.object.get("sha256"));
        if (sha.len > 0) try add(&out, a, 's', sha) else try add(&out, a, 'm', str(ch.object.get("md5")));
    };
    return out.toOwnedSlice(a);
}

fn storeCourse(a: std.mem.Allocator, st: db_mod.Stmt, url: []const u8, v: J) !void {
    if (v != .object) return;
    const hashes = try hashList(a, v.object);
    if (hashes.len == 0) return;
    var constraints: std.ArrayList(u8) = .empty;
    if (v.object.get("constraint")) |cs| if (cs == .array) for (cs.array.items) |x| {
        try constraints.appendSlice(a, str(x));
        try constraints.append(a, ',');
    };
    st.bindText(1, url);
    st.bindText(2, str(v.object.get("name")));
    st.bindText(3, hashes);
    st.bindText(4, constraints.items);
    _ = try st.step();
    st.reset();
}

pub const FetchResult = struct { songs: u32, courses: u32 };

/// Parses already-downloaded JSON into the DB, replacing what was stored for `url`.
pub fn store(gpa: std.mem.Allocator, d: Db, url: []const u8, head_bytes: []const u8, data_bytes: []const u8) !FetchResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const head = try parseJson(a, head_bytes);
    if (head != .object) return error.BadTable;
    const data = try parseJson(a, data_bytes);
    if (data != .array) return error.BadTable;

    var levels: std.ArrayList([]const u8) = .empty;
    if (head.object.get("level_order")) |lo| if (lo == .array) {
        for (lo.array.items) |l| try levels.append(a, try levelStr(a, l));
    };
    var extra: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (data.array.items) |e| {
        if (e != .object) continue;
        const l = try levelStr(a, e.object.get("level"));
        var known = false;
        for (levels.items) |k| known = known or std.mem.eql(u8, k, l);
        if (!known) try extra.put(a, l, {});
    }
    const rest = try a.dupe([]const u8, extra.keys());
    std.mem.sort([]const u8, rest, {}, levelLess);
    try levels.appendSlice(a, rest);

    try d.exec("BEGIN");
    errdefer d.exec("ROLLBACK") catch {};
    // Courses keep their rows, because their scores point at the ids. Empty hashes mark the ones to drop.
    for ([_][]const u8{ "DELETE FROM table_song WHERE url=?1", "UPDATE course SET hashes='' WHERE table_url=?1" }) |sql| {
        const del = try d.prepare(sql);
        defer del.deinit();
        del.bindText(1, url);
        _ = try del.step();
    }
    const meta = try d.prepare("INSERT OR REPLACE INTO bms_table(url,name,symbol,fetched) VALUES(?1,?2,?3,strftime('%s','now'))");
    defer meta.deinit();
    meta.bindText(1, url);
    meta.bindText(2, str(head.object.get("name")));
    meta.bindText(3, str(head.object.get("symbol")));
    _ = try meta.step();

    const ins = try d.prepare("INSERT INTO table_song(url,level,ord,md5,sha256,title,artist,zip_url,name_diff) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)");
    defer ins.deinit();
    var songs: u32 = 0;
    for (data.array.items, 0..) |e, i| {
        if (e != .object) continue;
        const o = e.object;
        const l = try levelStr(a, o.get("level"));
        var li: usize = 0;
        for (levels.items, 0..) |k, j| if (std.mem.eql(u8, k, l)) {
            li = j;
            break;
        };
        ins.bindText(1, url);
        ins.bindText(2, l);
        ins.bindInt(3, @intCast(li * 1_000_000 + i));
        ins.bindText(4, str(o.get("md5")));
        ins.bindText(5, str(o.get("sha256")));
        ins.bindText(6, str(o.get("title")));
        ins.bindText(7, str(o.get("artist")));
        const zip = str(o.get("url"));
        ins.bindText(8, if (refAllowed(url, zip)) zip else "");
        ins.bindText(9, str(o.get("url_diff")));
        _ = try ins.step();
        ins.reset();
        songs += 1;
    }
    var courses: u32 = 0;
    if (head.object.get("course")) |cv| if (cv == .array) {
        const cs = try d.prepare("INSERT INTO course(table_url,name,hashes,constraints) VALUES(?1,?2,?3,?4) ON CONFLICT(table_url,name) DO UPDATE SET hashes=excluded.hashes, constraints=excluded.constraints");
        defer cs.deinit();
        for (cv.array.items) |item| {
            // Both a flat list and a list of groups exist in the wild.
            if (item == .array) {
                for (item.array.items) |x| {
                    try storeCourse(a, cs, url, x);
                    courses += 1;
                }
            } else {
                try storeCourse(a, cs, url, item);
                courses += 1;
            }
        }
    };
    const gone = try d.prepare("DELETE FROM course WHERE table_url=?1 AND hashes=''");
    defer gone.deinit();
    gone.bindText(1, url);
    _ = try gone.step();
    // A later course can reuse a freed id, and must not inherit this score.
    try d.exec("DELETE FROM course_score WHERE course_id NOT IN (SELECT id FROM course)");
    try d.exec("COMMIT");
    return .{ .songs = songs, .courses = courses };
}

fn urlHost(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return null;
    const host = switch (uri.host orelse return null) {
        .raw, .percent_encoded => |h| h,
    };
    // Encoded hosts would hide an address from the check below.
    return if (std.mem.indexOfScalar(u8, host, '%') == null) host else null;
}

/// A hostile table must not make the game knock on the player's own network.
/// shortcut: checks the written host, not where its name resolves or a redirect goes; check the connected address if that matters.
fn isPrivateHost(written: []const u8) bool {
    const host = std.mem.trimEnd(u8, written, ".");
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    // Only global unicast is public, which also covers the spellings of ::1 and mapped IPv4.
    if (host.len > 0 and host[0] == '[') return host.len < 2 or (host[1] != '2' and host[1] != '3');
    const last = host[if (std.mem.lastIndexOfScalar(u8, host, '.')) |dot| dot + 1 else 0..];
    const is_number = for (last) |ch| {
        if (!std.ascii.isDigit(ch)) break false;
    } else true;
    if (!is_number and !std.ascii.startsWithIgnoreCase(last, "0x")) return false;
    // A resolver also reads 2130706433, 127.1, 0x7f.0.0.1 and 0177.0.0.1 as addresses, so only a plain quad can pass.
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    for (&octets) |*octet| {
        const text = it.next() orelse return true;
        if (text.len > 1 and text[0] == '0') return true;
        octet.* = std.fmt.parseInt(u8, text, 10) catch return true;
    }
    if (it.next() != null) return true;
    return octets[0] == 0 or octets[0] == 10 or octets[0] == 127 or (octets[0] == 169 and octets[1] == 254) or
        (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31) or (octets[0] == 192 and octets[1] == 168);
}

/// The player chose the table's own host, so a table on the home network can still use it.
fn refAllowed(table_url: []const u8, ref_url: []const u8) bool {
    const host = urlHost(ref_url) orelse return false;
    if (urlHost(table_url)) |own| if (std.ascii.eqlIgnoreCase(own, host)) return true;
    return !isPrivateHost(host);
}

pub fn fetch(gpa: std.mem.Allocator, d: Db, url: []const u8) !FetchResult {
    const page = try http.get(gpa, url);
    defer gpa.free(page);
    var head_url: []u8 = undefined;
    // Some entries point straight at the header JSON.
    if (findMeta(page)) |m| head_url = try http.join(gpa, url, m) else head_url = try gpa.dupe(u8, url);
    defer gpa.free(head_url);
    if (!refAllowed(url, head_url)) return error.BadTable;
    const head_bytes = if (std.mem.eql(u8, head_url, url)) try gpa.dupe(u8, page) else try http.get(gpa, head_url);
    defer gpa.free(head_bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const head = try parseJson(arena.allocator(), head_bytes);
    if (head != .object) return error.BadTable;
    const data_url = try http.join(arena.allocator(), head_url, str(head.object.get("data_url")));
    if (!refAllowed(url, data_url)) return error.BadTable;
    const data_bytes = try http.get(gpa, data_url);
    defer gpa.free(data_bytes);
    return store(gpa, d, url, head_bytes, data_bytes);
}

pub const CourseLimits = struct {
    /// Allowed random: 0 = off only, 1 = off or mirror, 2 = any.
    random: u8 = 2,
    no_speed: bool = false,
    no_good: bool = false,
    no_great: bool = false,
};

/// Constraint names follow beatoraja's CourseData.CourseDataConstraint.
pub fn parseConstraints(s: []const u8) CourseLimits {
    var l: CourseLimits = .{};
    var it = std.mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |n| {
        if (std.mem.eql(u8, n, "grade")) l.random = 0;
        if (std.mem.eql(u8, n, "grade_mirror")) l.random = 1;
        if (std.mem.eql(u8, n, "grade_random")) l.random = 2;
        if (std.mem.eql(u8, n, "no_speed")) l.no_speed = true;
        if (std.mem.eql(u8, n, "no_good")) l.no_good = true;
        if (std.mem.eql(u8, n, "no_great")) l.no_great = true;
    }
    return l;
}

test "a table cannot point at the player's own network" {
    const table = "https://example.com/t.html";
    for ([_][]const u8{
        "http://localhost/x",         "http://a.localhost/x", "http://127.0.0.1/x",
        "http://10.1.2.3/x",          "http://192.168.0.1/x", "http://172.16.0.1/x",
        "http://169.254.169.254/x",   "http://0.0.0.0/x",     "http://[::1]/x",
        "http://[fe80::1]/x",         "http://[fd00::1]/x",   "http://2130706433/x",
        "http://0x7f.0.0.1/x",        "file:///etc/passwd",   "http://127.1/x",
        "http://0177.0.0.1/x",        "http://127.0.0.1./x",  "http://%31%32%37.0.0.1/x",
        "http://[0:0:0:0:0:0:0:1]/x",
    }) |ref| try std.testing.expect(!refAllowed(table, ref));
    try std.testing.expect(refAllowed(table, "https://example.com/data.json"));
    try std.testing.expect(refAllowed(table, "http://172.32.0.1/x"));
    try std.testing.expect(refAllowed(table, "https://cafe.example/d.json"));
    try std.testing.expect(refAllowed("http://192.168.0.5/t.html", "http://192.168.0.5/d.json"));
}

test "meta tag and level order" {
    try std.testing.expectEqualStrings("head.json", findMeta("<html><META name=\"bmstable\" content=\"head.json\" /></html>").?);
    try std.testing.expectEqualStrings("h.json", findMeta("<meta content='h.json' name='bmstable'>").?);
    try std.testing.expect(findMeta("<meta charset=utf-8>") == null);
    const gpa = std.testing.allocator;
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try db_mod.initSchema(d);
    const head =
        \\{"name":"T","symbol":"t","data_url":"d.json","course":[[{"name":"C1","md5":["a","b"],"constraint":["grade","no_good"]}]]}
    ;
    const data =
        \\[{"md5":"m2","level":"10","title":"x","url":"https://example.org/x.zip"},{"md5":"m1","level":2,"title":"y","url":"http://192.168.0.1/y.zip"},{"md5":"m3","level":"?","title":"z"}]
    ;
    const r = try store(gpa, d, "https://example.com/t.html", head, data);
    try std.testing.expectEqual(@as(u32, 3), r.songs);
    try std.testing.expectEqual(@as(u32, 1), r.courses);
    const st = try d.prepare("SELECT md5, zip_url FROM table_song ORDER BY ord");
    defer st.deinit();
    // A download link into the player's own network is dropped.
    for ([_][2][]const u8{ .{ "m1", "" }, .{ "m2", "https://example.org/x.zip" }, .{ "m3", "" } }) |want| {
        try std.testing.expect(try st.step());
        try std.testing.expectEqualStrings(want[0], st.text(0));
        try std.testing.expectEqualStrings(want[1], st.text(1));
    }
    const lim = parseConstraints("grade,no_good,");
    try std.testing.expectEqual(@as(u8, 0), lim.random);
    try std.testing.expect(lim.no_good and !lim.no_great);
}

test "a table refresh keeps course scores on their courses" {
    const gpa = std.testing.allocator;
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try db_mod.initSchema(d);
    const head =
        \\{"name":"A","course":[{"name":"one","md5":["a"]},{"name":"two","md5":["b"]},{"name":"old","md5":["c"]}]}
    ;
    const reordered =
        \\{"name":"A","course":[{"name":"new","md5":["d"]},{"name":"two","md5":["e"]},{"name":"one","md5":["a"]}]}
    ;
    _ = try store(gpa, d, "A", head, "[]");
    _ = try store(gpa, d, "B", "{\"name\":\"B\",\"course\":[{\"name\":\"b1\",\"md5\":[\"x\"]}]}", "[]");
    try d.exec("INSERT INTO course_score(course_id,clear,ex,date) SELECT id,5,length(name),0 FROM course WHERE table_url='A'");
    _ = try store(gpa, d, "A", reordered, "[]");
    const q = try d.prepare("SELECT c.name,c.hashes,s.ex FROM course c LEFT JOIN course_score s ON s.course_id=c.id WHERE c.table_url='A' ORDER BY c.name");
    defer q.deinit();
    for ([_]struct { []const u8, []const u8, i64 }{ .{ "new", "m:d", 0 }, .{ "one", "m:a", 3 }, .{ "two", "m:e", 3 } }) |want| {
        try std.testing.expect(try q.step());
        try std.testing.expectEqualStrings(want[0], q.text(0));
        try std.testing.expectEqualStrings(want[1], q.text(1));
        try std.testing.expectEqual(want[2], q.int(2));
    }
    try std.testing.expect(!try q.step());
    const left = try d.prepare("SELECT COUNT(*) FROM course_score");
    defer left.deinit();
    try std.testing.expect(try left.step());
    try std.testing.expectEqual(@as(i64, 2), left.int(0));
}
