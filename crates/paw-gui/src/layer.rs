//! The still part of the scenes, kept in a texture, for a renderer that
//! draws on the processor (Mesa's llvmpipe).
//!
//! There every frame costs the filling of every pixel of every shape, and
//! the window draws a frame for each move of the song while it plays. Most
//! of a scene does not move then: only its bound roles (the playhead, the
//! meters, live values) and the role under the pointer do. The rest is
//! painted here into a texture as big as the window, in squares of 256
//! pixels, a square painted again only when a shape that reaches into it
//! changed; each frame copies the texture to the screen and draws, over
//! it, what moves. The shapes are egui's own, tessellated by egui and drawn
//! with egui's shader into a texture of the screen's size and place, so
//! that the pixels are those the shapes drawn on the screen would have.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use eframe::egui_glow;
use eframe::glow::{self, HasContext as _};
use egui::epaint::{ClippedShape, Primitive, Vertex};
use egui::{ClippedPrimitive, Rect, Shape, pos2};

/// The side of a square of the texture, in pixels.
pub const TILE: i32 = 256;

/// A square's column and row, from the window's top left.
type At = (i32, i32);

/// Columns and rows of squares, first and last of each.
type Range = ((i32, i32), (i32, i32));

/// What a frame knows of a pane: the scale and size of the screen its
/// squares were painted at, and the shapes each was painted from.
#[derive(Default)]
struct Pane {
    ppp: f32,
    screen: [i32; 2],
    tiles: HashMap<At, Vec<ClippedShape>>,
}

/// The still part of the panes drawn from scenes.
#[derive(Default)]
pub struct Layer {
    panes: HashMap<String, Pane>,
    /// The panes drawn in this frame.
    seen: HashSet<String>,
    gl: Arc<Mutex<Gl>>,
    /// How many squares were painted, all told, and how many pixels of
    /// them (what shows of their pane): `PAW_GUI_STATS` prints them.
    pub painted: u64,
    pub pixels: u64,
}

impl Layer {
    /// Whether the texture could not be made: then the scenes are drawn
    /// straight to the screen again.
    pub fn failed(&self) -> bool {
        self.gl.lock().is_ok_and(|gl| gl.failed)
    }

    /// The squares kept now, for every pane.
    #[cfg(test)]
    pub fn tiles(&self) -> usize {
        self.panes.values().map(|p| p.tiles.len()).sum()
    }

    /// The squares of the pane `id` that its still `shapes` make anew:
    /// those in sight whose shapes changed since they were painted, each
    /// with the shapes that reach into it. `rect` is the pane, `clip` what of it
    /// shows, in points; `ppp` pixels a point; `screen` the screen's size
    /// in pixels.
    fn plan(&mut self, id: &str, rect: Rect, clip: Rect, ppp: f32, screen: [i32; 2], shapes: &[ClippedShape]) -> Vec<(At, Vec<ClippedShape>)> {
        self.seen.insert(id.to_string());
        let pane = self.panes.entry(id.to_string()).or_default();
        if pane.ppp != ppp || pane.screen != screen {
            // Scaled, or a texture of another size: all of it again.
            pane.tiles.clear();
            pane.ppp = ppp;
            pane.screen = screen;
        }
        let shown = clip.intersect(rect);
        let Some(range) = tiles_in(shown, ppp) else { return Vec::new() };
        // The shapes in each square in sight, in their order.
        let mut by_tile: HashMap<At, Vec<&ClippedShape>> = HashMap::new();
        for shape in shapes {
            let bounds = shape.shape.visual_bounding_rect().intersect(shape.clip_rect);
            if !bounds.is_positive() {
                continue;
            }
            // A pixel more each way: the edge egui smooths reaches it.
            let Some(over) = tiles_in(bounds.expand(1.0 / ppp), ppp) else { continue };
            for ty in over.1.0.max(range.1.0)..=over.1.1.min(range.1.1) {
                for tx in over.0.0.max(range.0.0)..=over.0.1.min(range.0.1) {
                    by_tile.entry((tx, ty)).or_default().push(shape);
                }
            }
        }
        let mut fresh = Vec::new();
        for ty in range.1.0..=range.1.1 {
            for tx in range.0.0..=range.0.1 {
                let now = by_tile.remove(&(tx, ty)).unwrap_or_default();
                let kept = pane.tiles.get(&(tx, ty));
                if kept.is_some_and(|kept| kept.len() == now.len() && kept.iter().zip(&now).all(|(a, b)| same(a, b))) {
                    continue;
                }
                // Cut to the square by OpenGL when painted, not here: a
                // picture cut by egui is sampled a little elsewhere.
                let now: Vec<ClippedShape> = now.into_iter().cloned().collect();
                pane.tiles.insert((tx, ty), now.clone());
                fresh.push(((tx, ty), now));
            }
        }
        fresh
    }

    /// Draw the pane `id` from the texture: its squares whose still
    /// `shapes` changed are painted again first. The painter's cut is what
    /// of it shows.
    pub fn draw(&mut self, ctx: &egui::Context, painter: &egui::Painter, id: &str, rect: Rect, shapes: Vec<ClippedShape>) {
        let ppp = ctx.pixels_per_point();
        let clip = painter.clip_rect();
        let size = ctx.content_rect().max;
        let screen = [(size.x * ppp).round() as i32, (size.y * ppp).round() as i32];
        let fresh = self.plan(id, rect, clip, ppp, screen, &shapes);
        let shown = clip.intersect(rect);
        if !shown.is_positive() {
            return;
        }
        {
            let Ok(mut gl) = self.gl.lock() else { return };
            let pending = gl.pending.entry(id.to_string()).or_default();
            for (at, cut) in fresh {
                self.painted += 1;
                let square = Rect::from_min_size(pos2((at.0 * TILE) as f32, (at.1 * TILE) as f32) / ppp, egui::vec2(TILE as f32, TILE as f32) / ppp);
                let part = square.intersect(shown);
                self.pixels += (part.width().max(0.0) * part.height().max(0.0) * ppp * ppp).round() as u64;
                pending.insert(at, (shown, ctx.tessellate(cut, ppp)));
            }
        }
        let gl = self.gl.clone();
        let pane = id.to_string();
        let callback = egui_glow::CallbackFn::new(move |info, painter| {
            if let Ok(mut gl) = gl.lock() {
                gl.paint(painter, &info, &pane, shown);
            }
        });
        painter.add(Shape::Callback(egui::PaintCallback { rect: shown, callback: Arc::new(callback) }));
    }

    /// At the end of a frame: the panes not drawn in it are let go.
    pub fn frame_done(&mut self) {
        let seen = std::mem::take(&mut self.seen);
        let gone: Vec<String> = self.panes.keys().filter(|id| !seen.contains(*id)).cloned().collect();
        let Ok(mut gl) = self.gl.lock() else { return };
        for id in gone {
            self.panes.remove(&id);
            gl.pending.remove(&id);
        }
    }
}

/// The columns and rows of the squares that `rect` (points) reaches into;
/// None when it is empty.
fn tiles_in(rect: Rect, ppp: f32) -> Option<Range> {
    if !rect.is_positive() {
        return None;
    }
    let first = |v: f32| ((v * ppp).floor() as i32).div_euclid(TILE);
    let last = |v: f32| (((v * ppp).ceil() as i32) - 1).div_euclid(TILE);
    let (x0, x1, y0, y1) = (first(rect.min.x), last(rect.max.x), first(rect.min.y), last(rect.max.y));
    (x0 <= x1 && y0 <= y1).then_some(((x0, x1), (y0, y1)))
}

/// Two shapes the same: a text by its laid out lines, which are shared
/// while the text does not change, before they are compared.
fn same(a: &ClippedShape, b: &ClippedShape) -> bool {
    if a.clip_rect != b.clip_rect || a.transform_after_tessellation != b.transform_after_tessellation {
        return false;
    }
    match (&a.shape, &b.shape) {
        (Shape::Text(x), Shape::Text(y)) => {
            x.pos == y.pos
                && x.underline == y.underline
                && x.fallback_color == y.fallback_color
                && x.override_text_color == y.override_text_color
                && x.opacity_factor == y.opacity_factor
                && x.angle == y.angle
                && (Arc::ptr_eq(&x.galley, &y.galley) || x.galley == y.galley)
        }
        (x, y) => x == y,
    }
}

// ------------------------------------------------------------- OpenGL

/// The texture, and what to paint into it, kept where the paint callback
/// finds them.
#[derive(Default)]
struct Gl {
    kit: Option<Kit>,
    failed: bool,
    /// The texture as big as the screen, the framebuffer that paints into
    /// it, and its size.
    screen: Option<(glow::Texture, glow::Framebuffer, [u32; 2])>,
    /// By pane, the squares to paint, each with what of the pane shows and
    /// its shapes as egui tessellated them.
    pending: HashMap<String, HashMap<At, (Rect, Vec<ClippedPrimitive>)>>,
}

/// egui's shader, with its dithering switched (on to paint, off to copy).
struct Kit {
    program: glow::Program,
    u_screen_size: glow::UniformLocation,
    u_sampler: glow::UniformLocation,
    u_dither: glow::UniformLocation,
    vao: glow::VertexArray,
    vbo: glow::Buffer,
    ebo: glow::Buffer,
}

const VERTEX: &str = r#"
#if NEW_SHADER_INTERFACE
    #define I in
    #define O out
#else
    #define I attribute
    #define O varying
#endif
#ifdef GL_ES
    precision highp float;
#endif
uniform vec2 u_screen_size;
I vec2 a_pos;
I vec4 a_srgba;
I vec2 a_tc;
O vec4 v_rgba_in_gamma;
O vec2 v_tc;
void main() {
    gl_Position = vec4(2.0 * a_pos.x / u_screen_size.x - 1.0, 1.0 - 2.0 * a_pos.y / u_screen_size.y, 0.0, 1.0);
    v_rgba_in_gamma = a_srgba / 255.0;
    v_tc = a_tc;
}
"#;

const FRAGMENT: &str = r#"
#ifdef GL_ES
    precision highp float;
#endif
uniform sampler2D u_sampler;
uniform float u_dither;
#if NEW_SHADER_INTERFACE
    in vec4 v_rgba_in_gamma;
    in vec2 v_tc;
    out vec4 f_color;
    #define gl_FragColor f_color
    #define texture2D texture
#else
    varying vec4 v_rgba_in_gamma;
    varying vec2 v_tc;
#endif
float interleaved_gradient_noise(vec2 n) {
    float f = 0.06711056 * n.x + 0.00583715 * n.y;
    return fract(52.9829189 * fract(f));
}
vec3 dither_interleaved(vec3 rgb, float levels) {
    float noise = interleaved_gradient_noise(gl_FragCoord.xy);
    noise = (noise - 0.5) * 0.95;
    return rgb + noise / (levels - 1.0);
}
void main() {
    vec4 texture_in_gamma = texture2D(u_sampler, v_tc);
    vec4 frag_color_gamma = v_rgba_in_gamma * texture_in_gamma;
    if (u_dither > 0.5) {
        frag_color_gamma.rgb = dither_interleaved(frag_color_gamma.rgb, 256.);
    }
    gl_FragColor = frag_color_gamma;
}
"#;

impl Kit {
    unsafe fn new(gl: &glow::Context) -> Result<Kit, String> {
        unsafe {
            if gl.version().major < 3 && !gl.version().is_embedded {
                return Err("OpenGL 3 is needed".into());
            }
            let version = egui_glow::ShaderVersion::get(gl);
            let head = format!("{}\n#define NEW_SHADER_INTERFACE {}\n", version.version_declaration(), version.is_new_shader_interface() as i32);
            let program = gl.create_program()?;
            let mut shaders = Vec::new();
            for (kind, source) in [(glow::VERTEX_SHADER, VERTEX), (glow::FRAGMENT_SHADER, FRAGMENT)] {
                let shader = gl.create_shader(kind)?;
                gl.shader_source(shader, &format!("{head}{source}"));
                gl.compile_shader(shader);
                if !gl.get_shader_compile_status(shader) {
                    return Err(gl.get_shader_info_log(shader));
                }
                gl.attach_shader(program, shader);
                shaders.push(shader);
            }
            gl.link_program(program);
            if !gl.get_program_link_status(program) {
                return Err(gl.get_program_info_log(program));
            }
            for shader in shaders {
                gl.detach_shader(program, shader);
                gl.delete_shader(shader);
            }
            let uniform = |name: &str| gl.get_uniform_location(program, name).ok_or(format!("no uniform {name}"));
            let (u_screen_size, u_sampler, u_dither) = (uniform("u_screen_size")?, uniform("u_sampler")?, uniform("u_dither")?);
            let vbo = gl.create_buffer()?;
            let ebo = gl.create_buffer()?;
            let vao = gl.create_vertex_array()?;
            gl.bind_vertex_array(Some(vao));
            gl.bind_buffer(glow::ARRAY_BUFFER, Some(vbo));
            let stride = size_of::<Vertex>() as i32;
            for (name, size, kind, offset) in [
                ("a_pos", 2, glow::FLOAT, std::mem::offset_of!(Vertex, pos)),
                ("a_tc", 2, glow::FLOAT, std::mem::offset_of!(Vertex, uv)),
                ("a_srgba", 4, glow::UNSIGNED_BYTE, std::mem::offset_of!(Vertex, color)),
            ] {
                let at = gl.get_attrib_location(program, name).ok_or(format!("no attribute {name}"))?;
                gl.vertex_attrib_pointer_f32(at, size, kind, false, stride, offset as i32);
                gl.enable_vertex_attrib_array(at);
            }
            gl.bind_vertex_array(None);
            Ok(Kit { program, u_screen_size, u_sampler, u_dither, vao, vbo, ebo })
        }
    }

    unsafe fn mesh(&self, gl: &glow::Context, vertices: &[Vertex], indices: &[u32], texture: glow::Texture) {
        unsafe {
            let bytes = std::slice::from_raw_parts(vertices.as_ptr().cast::<u8>(), std::mem::size_of_val(vertices));
            gl.bind_buffer(glow::ARRAY_BUFFER, Some(self.vbo));
            gl.buffer_data_u8_slice(glow::ARRAY_BUFFER, bytes, glow::STREAM_DRAW);
            let bytes = std::slice::from_raw_parts(indices.as_ptr().cast::<u8>(), std::mem::size_of_val(indices));
            gl.bind_buffer(glow::ELEMENT_ARRAY_BUFFER, Some(self.ebo));
            gl.buffer_data_u8_slice(glow::ELEMENT_ARRAY_BUFFER, bytes, glow::STREAM_DRAW);
            gl.bind_texture(glow::TEXTURE_2D, Some(texture));
            gl.draw_elements(glow::TRIANGLES, indices.len() as i32, glow::UNSIGNED_INT, 0);
        }
    }
}

/// A rectangle in points as egui cuts to it, in pixels from the top left:
/// left, top, right, bottom.
fn clip_px(clip: Rect, ppp: f32, [w, h]: [u32; 2]) -> [i32; 4] {
    let l = ((clip.min.x * ppp).round() as i32).clamp(0, w as i32);
    let t = ((clip.min.y * ppp).round() as i32).clamp(0, h as i32);
    let r = ((clip.max.x * ppp).round() as i32).clamp(l, w as i32);
    let b = ((clip.max.y * ppp).round() as i32).clamp(t, h as i32);
    [l, t, r, b]
}

/// Cut OpenGL's drawing to `[l, t, r, b]` (pixels from the top left) on a
/// screen `h` pixels high; false when nothing is left.
unsafe fn scissor(gl: &glow::Context, [l, t, r, b]: [i32; 4], h: u32) -> bool {
    if l >= r || t >= b {
        return false;
    }
    unsafe { gl.scissor(l, h as i32 - b, r - l, b - t) };
    true
}

fn meet(a: [i32; 4], b: [i32; 4]) -> [i32; 4] {
    [a[0].max(b[0]), a[1].max(b[1]), a[2].min(b[2]), a[3].min(b[3])]
}

impl Gl {
    /// The texture of the screen's size, made (again) for `size`; its
    /// framebuffer. Made again, it holds nothing yet.
    unsafe fn screen(&mut self, gl: &glow::Context, size: [u32; 2]) -> Result<glow::Framebuffer, String> {
        unsafe {
            if let Some((_, fbo, made)) = self.screen
                && made == size
            {
                return Ok(fbo);
            }
            if let Some((texture, fbo, _)) = self.screen.take() {
                gl.delete_framebuffer(fbo);
                gl.delete_texture(texture);
            }
            let texture = gl.create_texture()?;
            gl.bind_texture(glow::TEXTURE_2D, Some(texture));
            for (name, value) in [
                (glow::TEXTURE_MIN_FILTER, glow::NEAREST),
                (glow::TEXTURE_MAG_FILTER, glow::NEAREST),
                (glow::TEXTURE_WRAP_S, glow::CLAMP_TO_EDGE),
                (glow::TEXTURE_WRAP_T, glow::CLAMP_TO_EDGE),
            ] {
                gl.tex_parameter_i32(glow::TEXTURE_2D, name, value as i32);
            }
            gl.tex_image_2d(glow::TEXTURE_2D, 0, glow::RGBA8 as i32, size[0] as i32, size[1] as i32, 0, glow::RGBA, glow::UNSIGNED_BYTE, glow::PixelUnpackData::Slice(None));
            let fbo = gl.create_framebuffer()?;
            gl.bind_framebuffer(glow::FRAMEBUFFER, Some(fbo));
            gl.framebuffer_texture_2d(glow::FRAMEBUFFER, glow::COLOR_ATTACHMENT0, glow::TEXTURE_2D, Some(texture), 0);
            if gl.check_framebuffer_status(glow::FRAMEBUFFER) != glow::FRAMEBUFFER_COMPLETE {
                gl.delete_framebuffer(fbo);
                gl.delete_texture(texture);
                return Err("a texture cannot be drawn into".into());
            }
            self.screen = Some((texture, fbo, size));
            Ok(fbo)
        }
    }

    /// In egui's paint callback for the pane `pane`, of which `shown`
    /// (points) shows: paint its squares that changed into the texture,
    /// then copy what shows of it to the screen.
    fn paint(&mut self, painter: &egui_glow::Painter, info: &egui::PaintCallbackInfo, pane: &str, shown: Rect) {
        if self.failed {
            return;
        }
        let gl = painter.gl().clone();
        let size = info.screen_size_px;
        let [w, h] = size;
        let ppp = info.pixels_per_point;
        unsafe {
            if self.kit.is_none() {
                match Kit::new(&gl) {
                    Ok(kit) => self.kit = Some(kit),
                    Err(err) => {
                        eprintln!("paw-gui: the panes are drawn straight: {err}");
                        self.failed = true;
                        return;
                    }
                }
            }
            let fbo = match self.screen(&gl, size) {
                Ok(fbo) => fbo,
                Err(err) => {
                    eprintln!("paw-gui: the panes are drawn straight: {err}");
                    self.failed = true;
                    gl.bind_framebuffer(glow::FRAMEBUFFER, painter.intermediate_fbo());
                    return;
                }
            };
            gl.disable(glow::CULL_FACE);
            gl.disable(glow::DEPTH_TEST);
            gl.color_mask(true, true, true, true);
            gl.enable(glow::BLEND);
            gl.blend_equation_separate(glow::FUNC_ADD, glow::FUNC_ADD);
            gl.blend_func_separate(glow::ONE, glow::ONE_MINUS_SRC_ALPHA, glow::ONE_MINUS_DST_ALPHA, glow::ONE);
            gl.active_texture(glow::TEXTURE0);
            // The texture is painted as the screen is: the same pixels.
            gl.viewport(0, 0, w as i32, h as i32);
            let kit = self.kit.as_ref().unwrap();
            gl.use_program(Some(kit.program));
            gl.uniform_1_i32(Some(&kit.u_sampler), 0);
            gl.uniform_2_f32(Some(&kit.u_screen_size), w as f32 / ppp, h as f32 / ppp);
            gl.bind_vertex_array(Some(kit.vao));
            gl.enable(glow::SCISSOR_TEST);
            let pending = self.pending.remove(pane).unwrap_or_default();
            if !pending.is_empty() {
                gl.bind_framebuffer(glow::FRAMEBUFFER, Some(fbo));
                gl.uniform_1_f32(Some(&kit.u_dither), 1.0);
                for ((tx, ty), (cut, primitives)) in pending {
                    // The square, as far as the pane shows in it: the panes
                    // beside it keep theirs.
                    let square = [tx * TILE, ty * TILE, (tx + 1) * TILE, (ty + 1) * TILE];
                    let mine = meet(square, clip_px(cut, ppp, size));
                    if !scissor(&gl, mine, h) {
                        continue;
                    }
                    gl.clear_color(0.0, 0.0, 0.0, 0.0);
                    gl.clear(glow::COLOR_BUFFER_BIT);
                    for ClippedPrimitive { clip_rect, primitive } in &primitives {
                        let Primitive::Mesh(mesh) = primitive else { continue };
                        let Some(texture) = painter.texture(mesh.texture_id) else { continue };
                        if scissor(&gl, meet(mine, clip_px(*clip_rect, ppp, size)), h) {
                            kit.mesh(&gl, &mesh.vertices, &mesh.indices, texture);
                        }
                    }
                }
            }
            // What shows of the pane, to the screen pixel for pixel.
            gl.bind_framebuffer(glow::FRAMEBUFFER, painter.intermediate_fbo());
            let cut = meet(clip_px(info.clip_rect, ppp, size), clip_px(shown, ppp, size));
            if scissor(&gl, cut, h) {
                gl.uniform_1_f32(Some(&kit.u_dither), 0.0);
                let (x0, y0, x1, y1) = (cut[0] as f32, cut[1] as f32, cut[2] as f32, cut[3] as f32);
                let at = |x: f32, y: f32| Vertex { pos: pos2(x / ppp, y / ppp), uv: pos2(x / w as f32, 1.0 - y / h as f32), color: egui::Color32::WHITE };
                let quad = [at(x0, y0), at(x1, y0), at(x1, y1), at(x0, y1)];
                let (texture, _, _) = self.screen.unwrap();
                kit.mesh(&gl, &quad, &[0, 1, 2, 0, 2, 3], texture);
            }
            gl.bind_vertex_array(None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use egui::{Color32, CornerRadius, vec2};

    const SCREEN: [i32; 2] = [1500, 960];

    fn fill(x: f32, y: f32, w: f32, h: f32, colour: Color32) -> ClippedShape {
        let everywhere = Rect::from_min_size(pos2(0.0, 0.0), vec2(4000.0, 4000.0));
        ClippedShape::new(everywhere, Shape::rect_filled(Rect::from_min_size(pos2(x, y), vec2(w, h)), CornerRadius::ZERO, colour))
    }

    fn ats(fresh: &[(At, Vec<ClippedShape>)]) -> Vec<At> {
        let mut out: Vec<At> = fresh.iter().map(|(at, _)| *at).collect();
        out.sort();
        out
    }

    #[test]
    fn only_the_squares_a_changed_shape_reaches_are_painted_again() {
        let mut layer = Layer::default();
        let pane = Rect::from_min_size(pos2(0.0, 0.0), vec2(600.0, 300.0));
        let mut shapes = vec![fill(0.0, 0.0, 600.0, 300.0, Color32::BLACK), fill(10.0, 50.0, 20.0, 20.0, Color32::RED)];
        let first = layer.plan("arrange", pane, pane, 1.0, SCREEN, &shapes);
        // 600 by 300 pixels: three columns and two rows of squares.
        assert_eq!(ats(&first), vec![(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (2, 1)]);
        assert!(layer.plan("arrange", pane, pane, 1.0, SCREEN, &shapes).is_empty(), "nothing changed, nothing is painted");
        shapes[1] = fill(10.0, 50.0, 20.0, 20.0, Color32::GREEN);
        assert_eq!(ats(&layer.plan("arrange", pane, pane, 1.0, SCREEN, &shapes)), vec![(0, 0)], "the square under the shape");
        // Across the line between two squares: both.
        shapes.push(fill(250.0, 60.0, 20.0, 10.0, Color32::BLUE));
        assert_eq!(ats(&layer.plan("arrange", pane, pane, 1.0, SCREEN, &shapes)), vec![(0, 0), (1, 0)]);
        // A shape taken away clears its squares.
        shapes.pop();
        assert_eq!(ats(&layer.plan("arrange", pane, pane, 1.0, SCREEN, &shapes)), vec![(0, 0), (1, 0)]);
    }

    #[test]
    fn a_scaled_window_is_painted_again_and_only_what_shows_is() {
        let mut layer = Layer::default();
        let pane = Rect::from_min_size(pos2(0.0, 0.0), vec2(600.0, 300.0));
        let shapes = vec![fill(0.0, 0.0, 600.0, 300.0, Color32::BLACK)];
        layer.plan("mixer", pane, pane, 1.0, SCREEN, &shapes);
        assert_eq!(layer.plan("mixer", pane, pane, 1.0, [1400, 900], &shapes).len(), 6, "another size of window: all");
        assert_eq!(layer.plan("mixer", pane, pane, 1.5, [1400, 900], &shapes).len(), 4 * 2, "at 1.5 pixels a point: 900 by 450 pixels");
        // Cut to its left part: the squares there only.
        let left = Rect::from_min_size(pos2(0.0, 0.0), vec2(200.0, 300.0));
        let mut other = Layer::default();
        assert_eq!(ats(&other.plan("mixer", pane, left, 1.0, SCREEN, &shapes)), vec![(0, 0), (0, 1)]);
        // A pane not drawn in a frame is let go.
        other.frame_done();
        assert_eq!(other.tiles(), 2);
        other.frame_done();
        assert_eq!(other.tiles(), 0);
    }

    #[test]
    fn a_square_is_painted_from_the_shapes_that_reach_into_it() {
        let mut layer = Layer::default();
        let pane = Rect::from_min_size(pos2(0.0, 0.0), vec2(300.0, 100.0));
        let shapes = [fill(0.0, 0.0, 300.0, 100.0, Color32::BLACK), fill(10.0, 10.0, 20.0, 20.0, Color32::RED)];
        let fresh = layer.plan("roll", pane, pane, 2.0, SCREEN, &shapes);
        // At two pixels a point a square is 128 points wide.
        let (_, first) = fresh.iter().find(|(at, _)| *at == (0, 0)).unwrap();
        let (_, second) = fresh.iter().find(|(at, _)| *at == (1, 0)).unwrap();
        assert_eq!((first.len(), second.len()), (2, 1), "the red square is in the first only");
        assert_eq!(second[0], shapes[0], "with its own cut: OpenGL cuts it to the square");
    }
}
