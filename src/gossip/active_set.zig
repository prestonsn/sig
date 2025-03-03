const std = @import("std");
const network = @import("zig-network");
const EndPoint = network.EndPoint;
const Thread = std.Thread;
const AtomicBool = std.atomic.Atomic(bool);
const UdpSocket = network.Socket;
const Tuple = std.meta.Tuple;
const crds = @import("../gossip/crds.zig");
const CrdsValue = crds.CrdsValue;

const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Pubkey = @import("../core/pubkey.zig").Pubkey;
const getWallclockMs = @import("../gossip/crds.zig").getWallclockMs;

const _crds_table = @import("../gossip/crds_table.zig");
const CrdsTable = _crds_table.CrdsTable;

const pull_request = @import("../gossip/pull_request.zig");

const Bloom = @import("../bloom/bloom.zig").Bloom;

const NUM_ACTIVE_SET_ENTRIES: usize = 25;
pub const CRDS_GOSSIP_PUSH_FANOUT: usize = 6;

const MIN_NUM_BLOOM_ITEMS: usize = 512;
const BLOOM_FALSE_RATE: f64 = 0.1;
const BLOOM_MAX_BITS: usize = 1024 * 8 * 4;

pub const ActiveSet = struct {
    // store pubkeys as keys in crds table bc the data can change
    pruned_peers: std.AutoHashMap(Pubkey, Bloom),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
    ) Self {
        return Self{ .pruned_peers = std.AutoHashMap(Pubkey, Bloom).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.pruned_peers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.pruned_peers.deinit();
    }

    pub fn len(self: *const Self) u32 {
        return self.pruned_peers.count();
    }

    pub fn rotate(
        self: *Self,
        crds_peers: []crds.LegacyContactInfo,
    ) error{OutOfMemory}!void {
        // clear the existing
        var iter = self.pruned_peers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.pruned_peers.clearRetainingCapacity();

        if (crds_peers.len == 0) {
            return;
        }
        const size = @min(crds_peers.len, NUM_ACTIVE_SET_ENTRIES);
        var rng = std.rand.DefaultPrng.init(getWallclockMs());
        pull_request.shuffleFirstN(rng.random(), crds.LegacyContactInfo, crds_peers, size);

        const bloom_num_items = @max(crds_peers.len, MIN_NUM_BLOOM_ITEMS);
        for (0..size) |i| {
            var entry = try self.pruned_peers.getOrPut(crds_peers[i].id);
            if (entry.found_existing == false) {
                // *full* hard restart on blooms -- labs doesnt do this - bug?
                var bloom = try Bloom.random(
                    self.allocator,
                    bloom_num_items,
                    BLOOM_FALSE_RATE,
                    BLOOM_MAX_BITS,
                );
                entry.value_ptr.* = bloom;
            }
        }
    }

    pub fn prune(self: *Self, from: Pubkey, origin: Pubkey) void {
        // we only prune peers which we are sending push messages to
        if (self.pruned_peers.getEntry(from)) |entry| {
            const origin_bytes = origin.data;
            entry.value_ptr.add(&origin_bytes);
        }
    }

    /// get a set of CRDS_GOSSIP_PUSH_FANOUT peers to send push messages to
    /// while accounting for peers that have been pruned from
    /// the given origin Pubkey
    pub fn getFanoutPeers(
        self: *const Self,
        allocator: std.mem.Allocator,
        origin: Pubkey,
        crds_table: *const CrdsTable,
    ) error{OutOfMemory}!std.ArrayList(EndPoint) {
        var active_set_endpoints = try std.ArrayList(EndPoint).initCapacity(allocator, CRDS_GOSSIP_PUSH_FANOUT);
        errdefer active_set_endpoints.deinit();

        // change to while loop
        var iter = self.pruned_peers.iterator();
        while (iter.next()) |entry| {
            // lookup peer contact info
            const peer_info = crds_table.get(crds.CrdsValueLabel{
                .LegacyContactInfo = entry.key_ptr.*,
            }) orelse continue; // peer pubkey could have been removed from the crds table
            const peer_gossip_addr = peer_info.value.data.LegacyContactInfo.gossip;

            crds.sanitizeSocket(&peer_gossip_addr) catch continue;

            // check if peer has been pruned
            const origin_bytes = origin.data;
            if (entry.value_ptr.contains(&origin_bytes)) {
                continue;
            }

            active_set_endpoints.appendAssumeCapacity(peer_gossip_addr.toEndpoint());
            if (active_set_endpoints.items.len == CRDS_GOSSIP_PUSH_FANOUT) {
                break;
            }
        }

        return active_set_endpoints;
    }
};

const ThreadPool = @import("../sync/thread_pool.zig").ThreadPool;

test "gossip.active_set: init/deinit" {
    var alloc = std.testing.allocator;

    var tp = ThreadPool.init(.{});
    var crds_table = try CrdsTable.init(alloc, &tp);
    defer crds_table.deinit();

    // insert some contacts
    var rng = std.rand.DefaultPrng.init(100);
    var gossip_peers = try std.ArrayList(crds.LegacyContactInfo).initCapacity(alloc, 10);
    defer gossip_peers.deinit();

    for (0..CRDS_GOSSIP_PUSH_FANOUT) |_| {
        var data = crds.LegacyContactInfo.random(rng.random());
        try gossip_peers.append(data);

        var keypair = try KeyPair.create(null);
        var value = try CrdsValue.initSigned(crds.CrdsData{
            .LegacyContactInfo = data,
        }, &keypair);
        try crds_table.insert(value, getWallclockMs());
    }

    var active_set = ActiveSet.init(alloc);
    defer active_set.deinit();
    try active_set.rotate(gossip_peers.items);

    try std.testing.expect(active_set.len() == CRDS_GOSSIP_PUSH_FANOUT);

    const origin = Pubkey.random(rng.random(), .{});

    var fanout = try active_set.getFanoutPeers(alloc, origin, &crds_table);
    defer fanout.deinit();
    const no_prune_fanout_len = fanout.items.len;
    try std.testing.expect(no_prune_fanout_len > 0);

    var iter = active_set.pruned_peers.keyIterator();
    const peer_pubkey = iter.next().?.*;
    active_set.prune(peer_pubkey, origin);

    var fanout_with_prune = try active_set.getFanoutPeers(alloc, origin, &crds_table);
    defer fanout_with_prune.deinit();
    try std.testing.expectEqual(no_prune_fanout_len, fanout_with_prune.items.len + 1);
}

test "gossip.active_set: gracefully rotates with duplicate contact ids" {
    var alloc = std.testing.allocator;

    var rng = std.rand.DefaultPrng.init(100);
    var gossip_peers = try std.ArrayList(crds.LegacyContactInfo).initCapacity(alloc, 10);
    defer gossip_peers.deinit();

    var data = crds.LegacyContactInfo.random(rng.random());
    var dupe = crds.LegacyContactInfo.random(rng.random());
    dupe.id = data.id;
    try gossip_peers.append(data);
    try gossip_peers.append(dupe);

    var active_set = ActiveSet.init(alloc);
    defer active_set.deinit();
    try active_set.rotate(gossip_peers.items);
}
