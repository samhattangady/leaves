const std = @import("std");
const c = @import("c.zig");
const constants = @import("constants.zig");

const glyph_lib = @import("glyphee.zig");
const TypeSetter = glyph_lib.TypeSetter;
const FONT_TEX_SIZE = glyph_lib.FONT_TEX_SIZE;
const CIRCLE_TEXTURE_SIZE = 512;

const helpers = @import("helpers.zig");
const Vector2 = helpers.Vector2;
const Vector2_gl = helpers.Vector2_gl;
const Vector3_gl = helpers.Vector3_gl;
const Vector4_gl = helpers.Vector4_gl;
const Matrix4_gl = helpers.Matrix4_gl;
const Camera2D = helpers.Camera2D;
const Camera3D = helpers.Camera3D;
const Mesh = helpers.Mesh;
const MeshVertex = helpers.MeshVertex;

const App = @import("app.zig").App;

const VERTEX_BASE_FILE: [:0]const u8 = @embedFile("../data/shaders/vertex.glsl");
const FRAGMENT_ALPHA_FILE: [:0]const u8 = @embedFile("../data/shaders/fragment_texalpha.glsl");
const VERTEX_3D_BASE_FILE: [:0]const u8 = @embedFile("../data/shaders/vertex_3d.glsl");
const FRAGMENT_3D_FILE: [:0]const u8 = @embedFile("../data/shaders/fragment_3d.glsl");
const SHADOW_MAP_SIZE = 2096;

const ShadowMap = struct {
    fbo: c.GLuint = 0,
    tex: c.GLuint = 0,
    light_cam: Camera3D = Camera3D.new_light(),
    proj: Matrix4_gl = .{},
    // TODO (04 May 2022 sam): Add a shader in here as well to make the depth pass
    // more efficient
};

const VertexData = struct {
    position: Vector3_gl = .{},
    texCoord: Vector2_gl = .{},
    color: Vector4_gl = .{},
};

const ShaderData = struct {
    const Self = @This();
    has_tris: bool = true,
    has_lines: bool = false,
    program: c.GLuint = 0,
    texture: c.GLuint = 0,
    triangle_verts: std.ArrayList(VertexData),
    indices: std.ArrayList(c_uint),

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .triangle_verts = std.ArrayList(VertexData).init(allocator),
            .indices = std.ArrayList(c_uint).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.triangle_verts.deinit();
        self.indices.deinit();
    }

    pub fn clear_buffers(self: *Self) void {
        self.triangle_verts.shrinkRetainingCapacity(0);
        self.indices.shrinkRetainingCapacity(0);
    }
};

pub const Renderer = struct {
    const Self = @This();
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    gl_context: c.SDL_GLContext,
    ticks: u32 = 0,
    vao: c.GLuint = 0,
    vao3d: c.GLuint = 0,
    vbo: c.GLuint = 0,
    vbo3d: c.GLuint = 0,
    ebo: c.GLuint = 0,
    leaf_shader: ShaderData,
    base_shader: ShaderData,
    text_shader: ShaderData,
    allocator: std.mem.Allocator,
    typesetter: *TypeSetter,
    cam2d: *Camera2D,
    cam3d: *Camera3D,
    shadow_map: ShadowMap = .{},
    z_val: f32 = 0.999,

    pub fn init(typesetter: *TypeSetter, cam2d: *Camera2D, cam3d: *Camera3D, allocator: std.mem.Allocator, window_title: []const u8) !Self {
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLESAMPLES, 16);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3); // OpenGL 3+
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3); // OpenGL 3.3
        const window = c.SDL_CreateWindow(window_title.ptr, c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, @floatToInt(c_int, constants.DEFAULT_WINDOW_WIDTH * cam2d.window_scale), @floatToInt(c_int, constants.DEFAULT_WINDOW_HEIGHT * cam2d.window_scale), c.SDL_WINDOW_OPENGL).?;
        const gl_context = c.SDL_GL_CreateContext(window);
        _ = c.SDL_GL_MakeCurrent(window, gl_context);
        _ = c.gladLoadGLLoader(@ptrCast(c.GLADloadproc, c.SDL_GL_GetProcAddress));
        var self = Self{
            .window = window,
            .renderer = undefined,
            .gl_context = gl_context,
            .allocator = allocator,
            .base_shader = ShaderData.init(allocator),
            .leaf_shader = ShaderData.init(allocator),
            .text_shader = ShaderData.init(allocator),
            .cam2d = cam2d,
            .cam3d = cam3d,
            .typesetter = typesetter,
        };
        try self.init_gl();
        try self.init_main_texture();
        try self.init_text_renderer();
        self.init_shadow_map();
        self.typesetter.free_texture_data();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.base_shader.deinit();
        self.leaf_shader.deinit();
        self.text_shader.deinit();
        c.SDL_DestroyWindow(self.window);
    }

    fn init_gl(self: *Self) !void {
        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glGenBuffers(1, &self.ebo);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        // TODO (13 Jun 2021 sam): Figure out where this gets saved. Currently both the vertex types have
        // the same attrib pointers, so it's okay for now, but once we have more programs, we would need
        // to see where this gets saved, and whether we need more vaos or vbos or whatever.
        c.glVertexAttribPointer(0, 3, c.GL_FLOAT, c.GL_FALSE, @sizeOf(VertexData), null);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(1, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(VertexData), @intToPtr(*const anyopaque, @offsetOf(VertexData, "color")));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(2, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(VertexData), @intToPtr(*const anyopaque, @offsetOf(VertexData, "texCoord")));
        c.glEnableVertexAttribArray(2);
        try self.init_shader_program(VERTEX_BASE_FILE, FRAGMENT_ALPHA_FILE, &self.text_shader);
        c.glGenVertexArrays(1, &self.vao3d);
        c.glBindVertexArray(self.vao3d);
        c.glGenBuffers(1, &self.vbo3d);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo3d);
        c.glVertexAttribPointer(0, 3, c.GL_FLOAT, c.GL_FALSE, @sizeOf(MeshVertex), null);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(1, 3, c.GL_FLOAT, c.GL_FALSE, @sizeOf(MeshVertex), @intToPtr(*const anyopaque, @offsetOf(MeshVertex, "normal")));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(2, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(MeshVertex), @intToPtr(*const anyopaque, @offsetOf(MeshVertex, "color")));
        c.glEnableVertexAttribArray(2);
        try self.init_shader_program(VERTEX_3D_BASE_FILE, FRAGMENT_3D_FILE, &self.base_shader);
    }

    fn init_shadow_map(self: *Self) void {
        c.glGenFramebuffers(1, &self.shadow_map.fbo);
        c.glGenTextures(1, &self.shadow_map.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.shadow_map.tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_DEPTH_COMPONENT, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, 0, c.GL_DEPTH_COMPONENT, c.GL_FLOAT, c.NULL);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.shadow_map.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_TEXTURE_2D, self.shadow_map.tex, 0);
        c.glDrawBuffer(c.GL_NONE);
        c.glReadBuffer(c.GL_NONE);
    }

    fn init_shader_program(self: *Self, vertex_src: []const u8, fragment_src: []const u8, shader_prog: *ShaderData) !void {
        _ = self;
        const fs: ?[*]const u8 = fragment_src.ptr;
        const fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
        c.glShaderSource(fragment_shader, 1, &fs, null);
        c.glCompileShader(fragment_shader);
        var compile_success: c_int = undefined;
        c.glGetShaderiv(fragment_shader, c.GL_COMPILE_STATUS, &compile_success);
        if (compile_success == 0) {
            std.debug.print("Fragment shader compilation failed\n", .{});
            var compile_message: [1024]u8 = undefined;
            c.glGetShaderInfoLog(fragment_shader, 1024, null, &compile_message[0]);
            std.debug.print("{s}\n", .{compile_message});
            return error.FragmentSyntaxError;
        }
        var vs: ?[*]const u8 = vertex_src.ptr;
        const vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
        c.glShaderSource(vertex_shader, 1, &vs, null);
        c.glCompileShader(vertex_shader);
        c.glGetShaderiv(vertex_shader, c.GL_COMPILE_STATUS, &compile_success);
        if (compile_success == 0) {
            std.debug.print("Vertex shader compilation failed\n", .{});
            var compile_message: [1024]u8 = undefined;
            c.glGetShaderInfoLog(vertex_shader, 1024, null, &compile_message[0]);
            std.debug.print("{s}\n", .{compile_message});
            return error.VertexSyntaxError;
        }
        shader_prog.program = c.glCreateProgram();
        c.glAttachShader(shader_prog.program, vertex_shader);
        c.glAttachShader(shader_prog.program, fragment_shader);
        c.glLinkProgram(shader_prog.program);
        c.glDeleteShader(vertex_shader);
        c.glDeleteShader(fragment_shader);
    }

    /// This currently only generates a circle texture that we can use to draw filled circles.
    fn init_main_texture(self: *Self) !void {
        if (true) return;
        if (true) unreachable; // check ig we are using this things.
        const temp_bitmap = try self.allocator.alloc(u8, CIRCLE_TEXTURE_SIZE * CIRCLE_TEXTURE_SIZE);
        defer self.allocator.free(temp_bitmap);
        // The circle texture leaves one pixel at 0,0 as filled, so all other fills can use that
        var i: usize = 0;
        var j: usize = 0;
        // First we initialise the temp_bitmap to 0.
        // TODO (01 May 2021 sam): Can we use memset here? Or some equivalent.
        // Also is this necessary? We anyway explicity set the pixel values of all pixels we use.
        while (i < CIRCLE_TEXTURE_SIZE) : (i += 1) {
            j = 0;
            while (j < CIRCLE_TEXTURE_SIZE) : (j += 1) {
                temp_bitmap[(i * CIRCLE_TEXTURE_SIZE) + j] = 0;
            }
        }
        temp_bitmap[0] = 255;
        const radius: usize = (CIRCLE_TEXTURE_SIZE - 1) / 2;
        const center = Vector2.from_usize(radius, radius);
        i = 1;
        while (i < CIRCLE_TEXTURE_SIZE) : (i += 1) {
            j = 1;
            while (j < CIRCLE_TEXTURE_SIZE) : (j += 1) {
                const current = Vector2.from_usize(i - 1, j - 1);
                if (Vector2.distance(center, current) <= @intToFloat(f32, radius)) {
                    temp_bitmap[(i * CIRCLE_TEXTURE_SIZE) + j] = 255;
                } else {
                    temp_bitmap[(i * CIRCLE_TEXTURE_SIZE) + j] = 0;
                }
            }
        }
        c.glGenTextures(1, &self.base_shader.texture);
        c.glBindTexture(c.GL_TEXTURE_2D, self.base_shader.texture);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RED, CIRCLE_TEXTURE_SIZE, CIRCLE_TEXTURE_SIZE, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &temp_bitmap[0]);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    }

    fn init_text_renderer(self: *Self) !void {
        c.glGenTextures(1, &self.text_shader.texture);
        c.glBindTexture(c.GL_TEXTURE_2D, self.text_shader.texture);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RED, FONT_TEX_SIZE, FONT_TEX_SIZE, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &self.typesetter.texture_data[0]);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    }

    pub fn render_app(self: *Self, ticks: u32, app: *App) void {
        self.ticks = ticks;
        // draw to shadow buffer
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.shadow_map.fbo);
        c.glViewport(0, 0, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE);
        c.glClear(c.GL_DEPTH_BUFFER_BIT);
        self.draw_mesh(app, &app.vines.mesh, &self.shadow_map.light_cam, false);
        if (!app.hide_leaves) self.draw_mesh(app, &app.vines.leaf_mesh, &self.shadow_map.light_cam, false);
        if (app.cube.color.w > 0.0) {
            self.draw_mesh(app, &app.cube, &self.shadow_map.light_cam, false);
        }
        // draw to screen
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        // c.glPolygonMode(c.GL_FRONT_AND_BACK, c.GL_LINE);
        c.glViewport(0, 0, @floatToInt(c_int, self.cam2d.window_size.x), @floatToInt(c_int, self.cam2d.window_size.y));
        c.glClearColor(0.1, 0.1, 0.1, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
        self.draw_mesh(app, &app.vines.mesh, self.cam3d, true);
        if (!app.hide_leaves) self.draw_mesh(app, &app.vines.leaf_mesh, self.cam3d, true);
        if (app.cube.color.w > 0.0) {
            self.draw_mesh(app, &app.cube, self.cam3d, true);
        }
        self.draw_buffers();
        c.SDL_GL_SwapWindow(self.window);
        self.clear_buffers();
    }

    fn draw_buffers(self: *Self) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        self.fill_text_buffers();
        self.draw_shader_buffers(&self.text_shader);
    }

    fn draw_mesh(self: *Self, app: *const App, mesh: *const Mesh, camera: *Camera3D, shadows: bool) void {
        if (mesh.vertices.items.len == 0) return;
        c.glUseProgram(self.base_shader.program);
        c.glBindVertexArray(self.vao3d);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo3d);
        c.glEnable(c.GL_BLEND);
        c.glEnable(c.GL_DEPTH_TEST);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glUniform1i(c.glGetUniformLocation(self.base_shader.program, "debug"), app.debug);
        {
            const uniform_location = c.glGetUniformLocation(self.base_shader.program, "model");
            c.glUniformMatrix4fv(uniform_location, 1, c.GL_FALSE, mesh.model.pointer());
        }
        {
            const uniform_location = c.glGetUniformLocation(self.base_shader.program, "view");
            c.glUniformMatrix4fv(uniform_location, 1, c.GL_FALSE, camera.view.pointer());
        }
        {
            const uniform_location = c.glGetUniformLocation(self.base_shader.program, "projection");
            c.glUniformMatrix4fv(uniform_location, 1, c.GL_FALSE, camera.projection.pointer());
        }
        {
            const uniform_location = c.glGetUniformLocation(self.base_shader.program, "light_view");
            c.glUniformMatrix4fv(uniform_location, 1, c.GL_FALSE, self.shadow_map.light_cam.view.pointer());
        }
        {
            const uniform_location = c.glGetUniformLocation(self.base_shader.program, "light_proj");
            c.glUniformMatrix4fv(uniform_location, 1, c.GL_FALSE, self.shadow_map.light_cam.projection.pointer());
        }
        {
            const uniform_location = c.glGetUniformLocation(self.base_shader.program, "color");
            const color = mesh.color;
            c.glUniform4f(uniform_location, color.x, color.y, color.z, color.w);
        }
        if (shadows) {
            c.glActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_2D, self.shadow_map.tex);
            c.glUniform1i(c.glGetUniformLocation(self.base_shader.program, "shadow_map"), 0);
        }
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(MeshVertex) * @intCast(c_longlong, mesh.vertices.items.len), &mesh.vertices.items[0], c.GL_DYNAMIC_DRAW);
        c.glDrawArrays(c.GL_TRIANGLES, @intCast(c.GLint, 0), @intCast(c.GLsizei, mesh.vertices.items.len));
    }

    fn draw_shader_buffers(self: *Self, shader: *ShaderData) void {
        c.glUseProgram(shader.program);
        c.glViewport(0, 0, @floatToInt(c_int, self.cam2d.window_size.x), @floatToInt(c_int, self.cam2d.window_size.y));
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glUniform1i(c.glGetUniformLocation(shader.program, "tex"), 0);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, shader.texture);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        if (shader.triangle_verts.items.len > 0 and shader.indices.items.len > 0) {
            c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(VertexData) * @intCast(c_longlong, shader.triangle_verts.items.len), &shader.triangle_verts.items[0], c.GL_DYNAMIC_DRAW);
            c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, self.ebo);
            c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(c_uint) * @intCast(c_longlong, shader.indices.items.len), &shader.indices.items[0], c.GL_DYNAMIC_DRAW);
            c.glDrawElements(c.GL_TRIANGLES, @intCast(c_int, shader.indices.items.len), c.GL_UNSIGNED_INT, null);
        }
    }

    fn fill_text_buffers(self: *Self) void {
        // This function fills the text buffers with character data from typesetter
        var i: usize = 0;
        while (i < self.typesetter.glyphs.items.len) : (i += 1) {
            const glyph = self.typesetter.glyphs.items[i];
            const quad = glyph.quad;
            const color = glyph.color;
            const z = glyph.z;
            const p1 = self.screen_pixel_to_gl(.{ .x = quad.x0, .y = quad.y0 }, self.cam2d.render_size(), z);
            const p2 = self.screen_pixel_to_gl(.{ .x = quad.x1, .y = quad.y1 }, self.cam2d.render_size(), z);
            const base = @intCast(c_uint, self.text_shader.triangle_verts.items.len);
            self.text_shader.triangle_verts.append(.{ .position = p1, .texCoord = .{ .x = quad.s0, .y = quad.t0 }, .color = color }) catch unreachable;
            self.text_shader.triangle_verts.append(.{ .position = .{ .x = p2.x, .y = p1.y, .z = 1.0 }, .texCoord = .{ .x = quad.s1, .y = quad.t0 }, .color = color }) catch unreachable;
            self.text_shader.triangle_verts.append(.{ .position = p2, .texCoord = .{ .x = quad.s1, .y = quad.t1 }, .color = color }) catch unreachable;
            self.text_shader.triangle_verts.append(.{ .position = .{ .x = p1.x, .y = p2.y, .z = 1.0 }, .texCoord = .{ .x = quad.s0, .y = quad.t1 }, .color = color }) catch unreachable;
            const indices = [_]c_uint{ base + 0, base + 1, base + 3, base + 1, base + 2, base + 3 };
            self.text_shader.indices.appendSlice(indices[0..6]) catch unreachable;
        }
    }

    // TODO (30 Sep 2021 sam): We might want to start off by storing all the positions in screen
    // coordinates, and then batch convert them to gl coordinates. Or do that in the vertex shader
    // @@Performance
    fn screen_pixel_to_gl(self: *Self, screen_pos: Vector2, screen_size: Vector2, z: f32) Vector3_gl {
        _ = z;
        const x = ((screen_pos.x / screen_size.x) * 2.0) - 1.0;
        const y = 1.0 - ((screen_pos.y / screen_size.y) * 2.0);
        self.z_val -= 0.00001;
        return .{ .x = x, .y = y, .z = self.z_val };
    }

    fn clear_buffers(self: *Self) void {
        self.base_shader.clear_buffers();
        self.leaf_shader.clear_buffers();
        self.text_shader.clear_buffers();
        self.typesetter.reset();
        self.z_val = 0.999;
    }
};
