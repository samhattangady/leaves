// leaves is a 3d visualisation of leaves climbing an object.

const std = @import("std");
const c = @import("c.zig");
const constants = @import("constants.zig");

const glyph_lib = @import("glyphee.zig");
const TypeSetter = glyph_lib.TypeSetter;

const vines_lib = @import("vines.zig");
const Vines = vines_lib.Vines;

const helpers = @import("helpers.zig");
const Vector2 = helpers.Vector2;
const Vector2_gl = helpers.Vector2_gl;
const Vector3_gl = helpers.Vector3_gl;
const Matrix3_gl = helpers.Matrix3_gl;
const Camera2D = helpers.Camera2D;
const Camera3D = helpers.Camera3D;
const SingleInput = helpers.SingleInput;
const MouseState = helpers.MouseState;
const EditableText = helpers.EditableText;
const Mesh = helpers.Mesh;
const MarchedCube = helpers.MarchedCube;
const TYPING_BUFFER_SIZE = 16;
const glf = c.GLfloat;
const ANIM_TICKS_LENGTH = 10000;
const AGING_TICKS_LENGTH = 3000;
const FALLING_TICKS_LENGTH = 5000;
const REWIND_ANIM_TICKS = 1300;
const TOTAL_TICKS = ANIM_TICKS_LENGTH + AGING_TICKS_LENGTH + FALLING_TICKS_LENGTH;

const InputKey = enum {
    shift,
    tab,
    enter,
    space,
    escape,
    ctrl,
};
const INPUT_KEYS_COUNT = @typeInfo(InputKey).Enum.fields.len;
const InputMap = struct {
    key: c.SDL_Keycode,
    input: InputKey,
};

const INPUT_MAPPING = [_]InputMap{
    .{ .key = c.SDLK_LSHIFT, .input = .shift },
    .{ .key = c.SDLK_LCTRL, .input = .ctrl },
    .{ .key = c.SDLK_RCTRL, .input = .ctrl },
    .{ .key = c.SDLK_TAB, .input = .tab },
    .{ .key = c.SDLK_RETURN, .input = .enter },
    .{ .key = c.SDLK_SPACE, .input = .space },
    .{ .key = c.SDLK_ESCAPE, .input = .escape },
};
const min = std.math.min;
const max = std.math.max;

pub const InputState = struct {
    const Self = @This();
    keys: [INPUT_KEYS_COUNT]SingleInput = [_]SingleInput{.{}} ** INPUT_KEYS_COUNT,
    mouse: MouseState = MouseState{},
    typed: [TYPING_BUFFER_SIZE]u8 = [_]u8{0} ** TYPING_BUFFER_SIZE,
    num_typed: usize = 0,

    pub fn get_key(self: *Self, key: InputKey) *SingleInput {
        return &self.keys[@enumToInt(key)];
    }

    pub fn type_key(self: *Self, k: u8) void {
        if (self.num_typed >= TYPING_BUFFER_SIZE) {
            std.debug.print("Typing buffer already filled.\n", .{});
            return;
        }
        self.typed[self.num_typed] = k;
        self.num_typed += 1;
    }

    pub fn reset(self: *Self) void {
        for (self.keys) |*key| key.reset();
        self.mouse.reset_mouse();
        self.num_typed = 0;
    }
};

pub fn smooth_sub(d1: glf, d2: glf, k: glf) glf {
    // float opSmoothSubtraction( float d1, float d2, float k ) {
    // float h = clamp( 0.5 - 0.5*(d2+d1)/k, 0.0, 1.0 );
    // return mix( d2, -d1, h ) + k*h*(1.0-h); }
    const h = std.math.clamp(0.5 - 0.5 * (d2 + d1) / k, 0.0, 1.0);
    return helpers.lerpf(d2, -d1, h) + k * h * (1.0 - h);
}

pub fn smooth_add(d1: glf, d2: glf, k: glf) glf {
    // float opSmoothUnion( float d1, float d2, float k ) {
    // float h = clamp( 0.5 + 0.5*(d2-d1)/k, 0.0, 1.0 );
    // return mix( d2, d1, h ) - k*h*(1.0-h); }
    const h = std.math.clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    return helpers.lerpf(d2, d1, h) - k * h * (1.0 - h);
}

pub fn sdf_default_cube(point: Vector3_gl) glf {
    const size = Vector3_gl{ .x = 0.5, .y = 0.5, .z = 0.5 };
    // https://iquilezles.org/articles/distfunctions/
    // vec3 q = abs(p) - b;
    // return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0)
    const q = (point.absed()).subtracted(size);
    return q.maxed(0.0).length() + min(max(q.x, max(q.y, q.z)), 0.0) - 0.01;
}

pub fn sdf_default_sphere(point: Vector3_gl) glf {
    return point.length() - 0.5;
}

pub fn sdf_sphere(point: Vector3_gl, center: Vector3_gl, radius: glf) glf {
    return point.distance_to(center) - radius;
}

pub fn sdf_cylinder(point: Vector3_gl, height: glf, radius: glf) glf {
    // float sdCappedCylinder( vec3 p, float h, float r )
    // {
    //   vec2 d = abs(vec2(length(p.xz),p.y)) - vec2(h,r); <- had to change this
    //   return min(max(d.x,d.y),0.0) + length(max(d,0.0));
    // }
    const temp = Vector2_gl{ .x = Vector2_gl.length(.{ .x = point.x, .y = point.z }), .y = point.y };
    const d = temp.absed().subtracted(.{ .x = radius, .y = height });
    return min(max(d.x, d.y), 0.0) + d.maxed(0.0).lengthed();
}

var sdf_count: usize = 0;
var model_num: usize = 6;

pub fn my_sdf(point: Vector3_gl) glf {
    var d = sdf_default_cube(point);
    if (model_num == 0) return d;
    var d2: glf = undefined;
    if (model_num == 1) {
        d2 = sdf_sphere(point, .{ .x = 0.5, .y = 0.0, .z = 0.0 }, 0.5);
        d = smooth_add(d, d2, 0.0);
        return d;
    }
    if (model_num == 2) {
        d2 = sdf_sphere(point, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, 0.5);
        d = smooth_add(d, d2, 0.0);
        return d;
    }
    if (model_num == 3) {
        d2 = sdf_sphere(point, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, 0.3);
        d = smooth_add(d, d2, 0.0);
        return d;
    }
    if (model_num == 4) {
        d2 = sdf_sphere(point, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, 0.3);
        d = smooth_add(d, d2, 0.3);
        return d;
    }
    d2 = sdf_sphere(point, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, 0.3);
    d = smooth_add(d, d2, 0.3);
    d2 = sdf_cylinder(point.rotated_about_point_axis(.{}, .{ .z = 1 }, std.math.pi / 2.0), 3.13, 0.125);
    d = smooth_sub(d2, d, 0.1);
    return d;
}

pub fn buffer_sdf(point: Vector3_gl) glf {
    return my_sdf(point) + 0.03;
}

pub const App = struct {
    const Self = @This();
    typesetter: TypeSetter = undefined,
    cam2d: Camera2D = .{},
    cam3d: Camera3D,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    ticks: u32 = 0,
    quit: bool = false,
    cube: Mesh,
    inputs: InputState = .{},
    vines: Vines,
    playing: bool = false,
    amount: glf = 0,
    leaf_age_amount: glf = 0,
    leaf_fall_amount: glf = 0,
    debug: c.GLint = 0,
    hide_leaves: bool = true,
    aging: bool = false,
    falling: bool = false,
    ticks_passed: u32 = 0,
    // doing this because the rewind was not working correctly.
    actual_ticks_passed: u32 = 0,

    pub fn new(allocator: std.mem.Allocator, arena: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .arena = arena,
            .cube = Mesh.init(allocator),
            .vines = Vines.init(allocator, arena),
            .cam3d = Camera3D.new(),
        };
    }

    pub fn init(self: *Self) !void {
        try self.typesetter.init(&self.cam2d, self.allocator);
        sdf_count = 0;
        self.cube.color = .{ .x = 0.8, .y = 0.8, .z = 0.9, .w = 1.0 };
        self.vines.mesh.color = .{ .x = 0.6, .y = 0.4, .z = 0.4, .w = 1.0 };
        self.vines.leaf_mesh.color = .{ .x = 0.45, .y = 0.65, .z = 0.3, .w = 1.0 };
        self.cube.generate_from_sdf(buffer_sdf, .{}, .{ .x = 1.5, .y = 1.5, .z = 1.5 }, 1.5 / 40.0, self.arena);
        sdf_count = 0;
        self.cube.align_normals(buffer_sdf);
        const start = std.time.milliTimestamp();
        // start vine growth
        {
            const point = Vector3_gl{ .y = 1.31 };
            const dir = Vector3_gl{ .y = -1, .x = 0.02 };
            sdf_count = 0;
            self.vines.grow(point, dir.normalized(), my_sdf, 1.0, 80.0);
            std.debug.print("grow called sdf {d} times\n", .{sdf_count});
        }
        const end = std.time.milliTimestamp();
        std.debug.print("vine growing took {d} ticks\n", .{end - start});
        if (false) {
            // cubes at vine points
            for (self.vines.vines.items) |vine| {
                for (vine.points.items) |point| {
                    var cube = Mesh.unit_cube(self.arena);
                    defer cube.deinit();
                    cube.set_position(point.position);
                    cube.set_scalef(0.05 * point.scale);
                    self.cube.append_mesh(&cube);
                }
            }
        }
        if (true) {
            // cubes at debug points
            for (self.vines.debug.items) |debug| {
                var cube = Mesh.unit_cube(self.arena);
                defer cube.deinit();
                cube.set_position(debug);
                cube.set_scalef(0.02);
                self.cube.append_mesh(&cube);
            }
        }
        const s2 = std.time.milliTimestamp();
        self.vines.regenerate_mesh(0.99999, 0, 0);
        const s3 = std.time.milliTimestamp();
        std.debug.print("mesh regen took {d} ticks\n", .{s3 - s2});
        if (false) {
            // Marching Cubes test
            var m = MarchedCube.init();
            const verts = [8]bool{
                // true, false, false, false, false, false, false, false,
                true, false, false, false, false, true, false, true,
            };
            m.generate_mesh(undefined, .{}, verts, &self.cube, self.arena);
            self.quit = true;
        }
    }

    pub fn deinit(self: *Self) void {
        self.typesetter.deinit();
        self.cube.deinit();
        self.vines.deinit();
    }

    pub fn handle_inputs(self: *Self, event: c.SDL_Event) void {
        if (event.@"type" == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_END)
            self.quit = true;
        self.inputs.mouse.handle_input(event, self.ticks, &self.cam2d);
        if (event.@"type" == c.SDL_KEYDOWN) {
            for (INPUT_MAPPING) |map| {
                if (event.key.keysym.sym == map.key) self.inputs.get_key(map.input).set_down(self.ticks);
            }
        } else if (event.@"type" == c.SDL_KEYUP) {
            for (INPUT_MAPPING) |map| {
                if (event.key.keysym.sym == map.key) self.inputs.get_key(map.input).set_release();
            }
        }
    }

    pub fn sdf_cube(self: *Self, point: Vector3_gl) c.GLfloat {
        _ = self;
        return sdf_default_cube(point);
    }

    // TODO (22 Apr 2022 sam): The direction calculation of the ray is wrong here. Needs to be fixed.
    pub fn ray_march(self: *Self, mouse_pos: Vector2) bool {
        const start = self.cam3d.position;
        // const forward = Vector3_gl{ .z = 1 };
        const lookat = self.cam3d.target.subtracted(self.cam3d.position).normalized();
        // we want a plane at z = 1, assuming the camera is at origin.
        const dx = std.math.tan(self.cam3d.fov * self.cam3d.aspect_ratio / 2.0);
        const dy = std.math.tan(self.cam3d.fov / 2.0);
        // we then find the point on that plane wrt mouse position, and get its length
        const px = ((mouse_pos.x / self.cam2d.render_size().x) * 2.0 - 1.0) * dx;
        const py = ((mouse_pos.y / self.cam2d.render_size().y) * 2.0 - 1.0) * dy;
        const point = Vector3_gl{ .x = px, .y = py, .z = 1 };
        // We then rotate the lookat based on the mouse pos, and scale to fit length
        const yaw_angle = ((mouse_pos.x / self.cam2d.render_size().x) * 2.0 - 1.0) * (self.cam3d.fov * self.cam3d.aspect_ratio / 2.0);
        const pitch_angle = ((mouse_pos.y / self.cam2d.render_size().y) * 2.0 - 1.0) * (self.cam3d.fov / 2.0);
        var direction = lookat.rotated_about_point_axis(.{}, self.cam3d.up, yaw_angle);
        direction = direction.rotated_about_point_axis(.{}, lookat.crossed(self.cam3d.up), -pitch_angle);
        const length = point.length();
        direction = direction.scaled(length);
        var dist: glf = 0.0;
        var i: usize = 0;
        var pos = start;
        while (i < 100) : (i += 1) {
            var d = self.sdf_cube(pos);
            pos = pos.added(direction.scaled(d));
            dist += d;
            if (d < 0.01) {
                return true;
            }
            if (dist > 20.0) {
                break;
            }
        }
        return false;
    }

    pub fn debug_ray_march(self: *Self) void {
        if (false) {
            self.debug = if (self.ray_march(self.inputs.mouse.current_pos)) 1 else 0;
            var x: f32 = 0;
            while (x < self.cam2d.render_size().x) : (x += 8) {
                var y: f32 = 0;
                while (y < self.cam2d.render_size().y) : (y += 8) {
                    if (self.ray_march(.{ .x = x, .y = y })) {
                        self.typesetter.draw_text_world_centered_font_color(.{ .x = x, .y = y }, "+", .debug, .{ .x = 1, .y = 0, .z = 0, .w = 1 });
                    }
                }
            }
        }
    }

    pub fn update(self: *Self, ticks: u32, arena: std.mem.Allocator) void {
        const delta = ticks - self.ticks;
        self.ticks = ticks;
        self.arena = arena;
        self.debug_ray_march();
        self.vines.update(ticks, arena);
        self.debug = if (self.inputs.get_key(.shift).is_down) 1 else 0;
        if (self.inputs.mouse.r_button.is_down) {
            self.amount = self.inputs.mouse.current_pos.x / self.cam2d.render_size().x;
        }
        if (self.inputs.mouse.m_button.is_clicked) {
            model_num += 1;
            self.cube.generate_from_sdf(buffer_sdf, .{}, .{ .x = 1.5, .y = 1.5, .z = 1.5 }, 1.5 / 40.0, self.arena);
            self.cube.align_normals(buffer_sdf);
        }
        if (self.inputs.get_key(.space).is_clicked) {
            self.playing = !self.playing;
        }
        if (self.inputs.get_key(.tab).is_clicked) {
            std.debug.print("ticks_passed = {d}\n", .{self.ticks_passed});
            std.debug.print("camera_position = {d}, {d}, {d}\n", .{ self.cam3d.position.x, self.cam3d.position.y, self.cam3d.position.z });
        }
        if (self.inputs.mouse.r_button.is_down) {
            self.playing = false;
            const fract = self.inputs.mouse.current_pos.x / self.cam2d.render_size().x;
            self.actual_ticks_passed = @floatToInt(u32, fract * TOTAL_TICKS);
        }
        if (self.playing) {
            self.actual_ticks_passed += delta;
            if (self.actual_ticks_passed >= TOTAL_TICKS + REWIND_ANIM_TICKS) {
                self.playing = false;
            }
            self.update_ticks_passed(self.actual_ticks_passed);
            self.update_amounts(self.ticks_passed);
            self.update_camera(self.ticks_passed);
        }
        self.camera_controls();
        self.cube.color.w = 1.0 - self.leaf_age_amount;
        self.cube.update_vertex_colors();
        self.vines.leaf_mesh.color = helpers.Vector4_gl.lerp(.{ .x = 0.45, .y = 0.65, .z = 0.3, .w = 1.0 }, .{ .x = 0.65, .y = 0.45, .z = 0.3, .w = 1.0 }, self.leaf_age_amount);
        self.vines.regenerate_mesh(helpers.quad_ease_in_f(0.0, 1.0, self.amount), self.leaf_fall_amount, self.ticks);
    }

    fn update_ticks_passed(self: *Self, ticks: u32) void {
        self.ticks_passed = ticks;
        if (self.ticks_passed > TOTAL_TICKS and self.ticks_passed < TOTAL_TICKS + REWIND_ANIM_TICKS) {
            const t = ticks - TOTAL_TICKS;
            const fract = 1.0 - @intToFloat(f32, t) / REWIND_ANIM_TICKS;
            self.ticks_passed = @floatToInt(u32, fract * TOTAL_TICKS);
        } else if (self.ticks_passed >= TOTAL_TICKS + REWIND_ANIM_TICKS) {
            self.ticks_passed = 0;
        }
    }

    fn update_amounts(self: *Self, ticks: u32) void {
        if (ticks < ANIM_TICKS_LENGTH) {
            self.amount = @intToFloat(f32, ticks) / @intToFloat(f32, ANIM_TICKS_LENGTH);
        } else {
            self.amount = 1.0;
            if (ticks < (ANIM_TICKS_LENGTH + AGING_TICKS_LENGTH)) {
                self.leaf_age_amount = @intToFloat(f32, ticks - ANIM_TICKS_LENGTH) / @intToFloat(f32, AGING_TICKS_LENGTH);
            } else {
                self.leaf_age_amount = 1.0;
                if (ticks < (TOTAL_TICKS)) {
                    self.leaf_fall_amount = @intToFloat(f32, ticks - ANIM_TICKS_LENGTH - AGING_TICKS_LENGTH) / @intToFloat(f32, FALLING_TICKS_LENGTH);
                } else {
                    self.leaf_fall_amount = 1.0;
                    if (ticks < (TOTAL_TICKS + REWIND_ANIM_TICKS)) {
                        const t = ticks - TOTAL_TICKS;
                        const fract = 1.0 - @intToFloat(f32, t) / REWIND_ANIM_TICKS;
                        self.update_amounts(@floatToInt(u32, fract * TOTAL_TICKS));
                        _ = fract;
                    }
                }
            }
        }
    }

    fn update_camera(self: *Self, ticks_raw: u32) void {
        var ticks_fract: f32 = undefined;
        if (ticks_raw > TOTAL_TICKS and ticks_raw < TOTAL_TICKS + REWIND_ANIM_TICKS) {
            const t = ticks_raw - TOTAL_TICKS;
            const fract = 1.0 - (@intToFloat(f32, t) / REWIND_ANIM_TICKS);
            ticks_fract = fract;
        } else {
            ticks_fract = @intToFloat(f32, ticks_raw) / TOTAL_TICKS;
        }
        const cam_start = Vector3_gl{ .x = 6.780282974243164, .y = -0.4565243124961853, .z = -0.8648737072944641 };
        const x_rad = helpers.easeinoutf(-helpers.PI / 6.0, helpers.PI * 1.6, ticks_fract);
        const y_rad = helpers.PI / 30.0 + helpers.easeinoutf(-helpers.PI / 12.0, helpers.PI / 8.0, ticks_fract);
        const zoom = helpers.easeinoutf(1.0, 1.3, ticks_fract);
        self.cam3d.position = cam_start.scaled(zoom).rotated_about_point_axis(self.cam3d.target, .{ .y = 1 }, x_rad);
        const y_axis = Vector3_gl.cross(self.cam3d.position.subtracted(self.cam3d.target), .{ .y = 1 }).normalized();
        self.cam3d.position = self.cam3d.position.rotated_about_point_axis(self.cam3d.target, y_axis, y_rad);
        self.cam3d.update_view();
    }

    fn cam_lerp(p0: Vector3_gl, p1: Vector3_gl, amount: f32) Vector3_gl {
        return p0.lerped(p1, amount);
    }

    pub fn camera_controls(self: *Self) void {
        var should_update_view = false;
        if (self.inputs.mouse.l_button.is_down) {
            if (self.inputs.mouse.movement()) |moved| {
                const x_rad = 1.0 * (moved.x * std.math.pi * 2) / self.cam2d.render_size().x;
                const y_rad = -1.0 * (moved.y * std.math.pi * 2) / self.cam2d.render_size().y;
                // rotation axis for y mouse movement... not actual y axis...
                const y_axis = Vector3_gl.cross(self.cam3d.position.subtracted(self.cam3d.target), .{ .y = 1 }).normalized();
                self.cam3d.position = self.cam3d.position.rotated_about_point_axis(self.cam3d.target, .{ .y = 1 }, x_rad);
                self.cam3d.position = self.cam3d.position.rotated_about_point_axis(self.cam3d.target, y_axis, y_rad);
                should_update_view = true;
            }
        }
        if (self.inputs.mouse.wheel_y != 0) {
            const scrolled = @intToFloat(c.GLfloat, -self.inputs.mouse.wheel_y);
            const zoom = std.math.pow(c.GLfloat, 1.1, scrolled);
            self.cam3d.position = self.cam3d.position.scaled_anchor(zoom, self.cam3d.target);
            should_update_view = true;
        }
        if (should_update_view) self.cam3d.update_view();
    }

    pub fn end_frame(self: *Self) void {
        self.inputs.mouse.reset_mouse();
        self.inputs.reset();
    }
};
