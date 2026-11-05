const std = @import("std");
const release_sig = @import("release_sig");
const Ed25519 = release_sig.Ed25519;

const usage =
    \\usage: release_sign keygen <secret-key-file>
    \\       release_sign sign <secret-key-file> <tag> <asset>...
    \\keygen writes a new secret key and prints the public key for -Dupdate-key.
    \\sign writes <asset>.sig beside each asset of release <tag>.
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const cwd = std.Io.Dir.cwd();
    if (args.len == 3 and std.mem.eql(u8, args[1], "keygen")) {
        const pair = Ed25519.KeyPair.generate(io);
        // Exclusive, so a second keygen can never destroy the key every installed game trusts.
        const f = try cwd.createFile(io, args[2], .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, &pair.secret_key.toBytes());
        try std.Io.File.stdout().writeStreamingAll(io, &std.fmt.bytesToHex(pair.public_key.toBytes(), .lower) ++ "\n");
        return;
    }
    if (args.len < 5 or !std.mem.eql(u8, args[1], "sign")) {
        std.debug.print(usage, .{});
        return error.Usage;
    }
    const secret = try cwd.readFileAlloc(io, args[2], a, .limited(Ed25519.SecretKey.encoded_length + 1));
    if (secret.len != Ed25519.SecretKey.encoded_length) return error.BadSecretKey;
    const pair = try Ed25519.KeyPair.fromSecretKey(try .fromBytes(secret[0..Ed25519.SecretKey.encoded_length].*));
    try release_sig.checkTag(args[3]);
    for (args[4..]) |path| {
        // A second run over out/* would otherwise sign the signatures too.
        if (std.mem.endsWith(u8, path, ".sig")) continue;
        const bytes = try cwd.readFileAlloc(io, path, a, .limited(1 << 32));
        var sum: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
        a.free(bytes);
        const name = try std.fmt.allocPrint(a, "{s}/{s}", .{ args[3], std.fs.path.basename(path) });
        const sig = try pair.sign(try release_sig.message(a, name, sum), null);
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.sig", .{path}), .data = &sig.toBytes() });
        std.debug.print("signed {s}\n", .{name});
    }
}
