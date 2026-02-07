const std = @import("std");

pub fn score(query: []const u8, text: []const u8) ?usize {
    if (query.len == 0) return 0;

    var qi: usize = 0;
    var sc: usize = 0;

    for (text, 0..) |c, i| {
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) {
            sc += i;
            qi += 1;
            if (qi == query.len) break;
        }
    }

    if (qi != query.len) return null;
    return sc + (text.len - query.len);
}

pub fn isMatch(query: []const u8, text: []const u8) bool {
    return score(query, text) != null;
}
