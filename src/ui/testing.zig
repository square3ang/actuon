//! `g` stays undefined: key handlers may only pass its window to SDL, which refuses it.
const std = @import("std");
const app_mod = @import("app.zig");
const select = @import("select.zig");
const settings = @import("settings.zig");
const db_mod = @import("../db/db.zig");
const engine_mod = @import("../audio/engine.zig");
const fs = @import("../platform/fs.zig");
const App = app_mod.App;

const library =
    \\INSERT INTO song(path,folder,sha256,md5,title,level) VALUES
    \\ ('/a/1.bms','/a','sha1','md1','Alpha','3'),
    \\ ('/a/2.bms','/a','sha2','md2','Beta','9'),
    \\ ('/a/3.bms','/a','sha3','md3','Gamma','5'),
    \\ ('/b/1.bms','/b','sha4','md4','Delta','1');
    \\INSERT INTO bms_table(url,name,symbol) VALUES('https://t.example/','Table','*');
    \\INSERT INTO table_song(url,level,ord,md5,sha256,title) VALUES
    \\ ('https://t.example/','3',0,'md1','','Alpha'),
    \\ ('https://t.example/','3',1,'md9','','Lost');
    \\INSERT INTO course(table_url,name,hashes,constraints) VALUES('https://t.example/','Dan','m:md1','');
;

pub fn open() !*App {
    const gpa = std.testing.allocator;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    try fs.mkdirs(std.testing.io, try fs.dataDir(arena.allocator()));
    const db = try db_mod.Db.open(":memory:", gpa, false);
    try db_mod.initSchema(db);
    try db.exec(library);
    const a = try gpa.create(App);
    a.* = .{
        .gpa = gpa,
        .io = std.testing.io,
        .arena = arena,
        .cfg = .{ .tables = &.{} },
        .cfg_file = .read,
        .g = undefined,
        .engine = try engine_mod.Engine.create(gpa),
        .db = db,
        .sel = .{},
    };
    select.reload(a);
    return a;
}

pub fn close(a: *App) void {
    const gpa = a.gpa;
    if (a.sel.search.len > 0) gpa.free(a.sel.search);
    if (a.sel.arena) |*ar| ar.deinit();
    if (a.sel.replay_arena) |*r| r.deinit();
    settings.freeDrop(&a.set);
    a.text.deinit(gpa);
    a.engine.destroy();
    a.db.close();
    a.arena.deinit();
    gpa.destroy(a.arena);
    gpa.destroy(a);
}
