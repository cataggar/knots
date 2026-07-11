pub const Usage = struct {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    copy_dst: bool = false,
    copy_src: bool = false,
    storage: bool = false,
};

pub const Desc = struct {
    size: usize,
    usage: Usage,
    label: []const u8 = "",
};
