pub const Key = struct {
    codepoint: u32,
    size_px: u32, // fixed-point: actual_size * 64
};

pub const Metrics = struct {
    rect: Rect,
    bearing_x: f32,
    bearing_y: f32,
    advance: f32,
};

pub const Shaped = struct {
    metrics: Metrics,
    x: f32, // pen position
    y: f32,
};

pub const ShapedText = struct {
    glyphs: []Shaped,
    width: f32,
};

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    line_count: u32,
};

pub const Rect = struct {
    u: f32,
    v: f32,
    uw: f32,
    uh: f32,
    width: f32,
    height: f32,
};
